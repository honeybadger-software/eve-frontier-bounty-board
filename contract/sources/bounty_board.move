/// Honey Badger Bounty Board - put a price on a pilot's head in EVE Frontier.
///
/// WHAT A PLAYER GETS
///   Anyone can post a bounty on a pilot: coins (the game's EVE token, SUI, any coin) locked in a shared on-chain
///   object, with an expiry date. The pilot who destroys the target's SHIP collects the whole bounty by showing the
///   game's own killmail. If nobody collects, the poster takes the coins back once the refund window opens.
///
/// WHY IT NEEDS NO STRUCTURE
///   Unlike a storage-unit, gate or turret mod, nothing has to be anchored or authorized in game: killmails are
///   created by the game itself (world::killmail::create_killmail, sponsor-only) as shared objects anyone can read,
///   and characters are shared objects too. So the board works for every pilot as soon as it is published.
///
/// THE RULES THE CODE ENFORCES (each has a test in tests/bounty_board_tests.move)
///   1. The kill must be a SHIP loss (a structure loss does not count).
///   2. The killmail's victim must be the bounty's target (same pilot, same game tenant).
///   3. The killmail's killer must be the character the claimant presents, and that character must belong to the
///      wallet sending the claim (you cannot cash in someone else's kill).
///   4. The kill must happen after the bounty was posted and no later than its expiry (the killmail's own time).
///   5. The target cannot collect on themselves: not with their own character (the game does record ship losses
///      where killer and victim are the same pilot) and not with another character on the target's wallet.
///      Farming with an alt on a DIFFERENT wallet cannot be told apart on chain; it costs the farmer a ship.
///      (An audit showed a tribe rule would refuse ~40% of honest kills - 96.7% of Stillness pilots share the
///      starter tribe - and a tribe hop defeats it anyway, so there is none.)
///   6. You cannot post a bounty on yourself.
///   7. Refunds only go to the poster, and only REFUND_GRACE_MS (7 days) after expiry: killmails reach the chain
///      late (measured on Stillness: median ~20 min, 1 in 10 more than 11 h, some several days), and a refund
///      deletes the bounty, so the window protects hunters whose killmail is still on its way.
///   8. Each bounty pays once: claiming or refunding deletes it. Several bounties on one pilot all pay out for the
///      same kill (they stack), one claim each.
///   9. The board has an on/off switch for NEW bounties and a version number (BoardConfig, changed only with the
///      AdminCap the publisher receives). Posting and claiming check both; REFUNDING NEVER DOES, so nobody - not
///      even the admin - can ever freeze a poster's coins. The switch exists for when CCP moves Stillness to a new
///      world package: old-world killmails stop, so new bounties must stop too. The version lets a published fix be
///      enforced (Sui keeps every old package version callable).
///
/// TIME UNITS: the Sui Clock is in milliseconds; a killmail's kill_timestamp is in SECONDS (world killmail.move).
module hb_bounty::bounty_board;

use std::{ascii, type_name};
use sui::{balance::Balance, clock::Clock, coin::{Self, Coin}, event};
use world::{character::Character, in_game_id::TenantItemId, killmail::Killmail};

// === Errors (numbers are what a failed transaction reports) ===
const EZeroReward: u64 = 0;
const EBadDuration: u64 = 1;
const ESelfBounty: u64 = 2;
const ENotAShipKill: u64 = 3;
const EWrongVictim: u64 = 4;
const ENotTheKiller: u64 = 5;
const ENotYourCharacter: u64 = 6;
const EKillBeforeBounty: u64 = 7;
const EKillAfterExpiry: u64 = 8;
// 9 was the tribe rule (removed before the first publish, see rule 5).
const ENotExpired: u64 = 10;
const ENotThePlacer: u64 = 11;
const ESelfClaim: u64 = 12;
const EWrongVersion: u64 = 13;
const EPlacingClosed: u64 = 14;
const ENotAnUpgrade: u64 = 15;

// === Limits ===
const MIN_DURATION_MS: u64 = 60 * 60 * 1000;            // 1 hour: long enough to be hunted
const MAX_DURATION_MS: u64 = 14 * 24 * 60 * 60 * 1000;  // 14 days: with the grace, coins are locked 21 days at most
const REFUND_GRACE_MS: u64 = 7 * 24 * 60 * 60 * 1000;   // 7 days: late killmails can still be claimed (rule 7)

/// Bump when a published upgrade must replace the rules; then call migrate() with the AdminCap.
const VERSION: u64 = 1;

/// The board's settings: one shared object, created when the package is published.
public struct BoardConfig has key {
    id: UID,
    version: u64,
    placing_enabled: bool,
}

/// Held by the publisher: switches new bounties on or off and migrates the version. It can never touch refunds.
public struct AdminCap has key, store {
    id: UID,
}

/// One bounty. A shared object, so the hunter and the poster can both reach it; deleted when it pays out.
/// `T` is the coin type (e.g. the game's EVE token or SUI).
public struct Bounty<phantom T> has key {
    id: UID,
    /// The target's in-game identity, exactly as killmails name victims (item id + tenant).
    target: TenantItemId,
    /// The target's Character object (for the dApp to show a name).
    target_character: ID,
    /// The target's wallet when the bounty was posted: characters on it cannot collect (rule 5).
    target_address: address,
    /// Who posted it and gets the refund.
    placer: address,
    reward: Balance<T>,
    /// When it was posted, in SECONDS (compared with killmail times).
    placed_at_s: u64,
    /// When it runs out, in MILLISECONDS (Sui Clock time).
    expires_at_ms: u64,
}

// === Events (the companion app and the dApp read these) ===
public struct BountyPlacedEvent has copy, drop {
    bounty_id: ID,
    target: TenantItemId,
    target_character: ID,
    placer: address,
    amount: u64,
    coin_type: ascii::String,
    expires_at_ms: u64,
}

public struct BountyClaimedEvent has copy, drop {
    bounty_id: ID,
    target: TenantItemId,
    killmail_id: ID,
    killer: TenantItemId,
    claimant: address,
    amount: u64,
    coin_type: ascii::String,
}

public struct BountyRefundedEvent has copy, drop {
    bounty_id: ID,
    placer: address,
    amount: u64,
    coin_type: ascii::String,
}

public struct PlacingSwitchedEvent has copy, drop {
    enabled: bool,
}

// === Publishing ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(BoardConfig { id: object::new(ctx), version: VERSION, placing_enabled: true });
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

// === Posting ===

/// Put `reward` on `target`'s head for `duration_ms` (1 hour to 14 days). Returns the new bounty's id.
public fun place<T>(config: &BoardConfig, target: &Character, reward: Coin<T>, duration_ms: u64, clock: &Clock,
                    ctx: &mut TxContext): ID {
    assert!(config.version == VERSION, EWrongVersion);                           // rule 9
    assert!(config.placing_enabled, EPlacingClosed);                              // rule 9
    let amount = reward.value();
    assert!(amount > 0, EZeroReward);
    assert!(duration_ms >= MIN_DURATION_MS && duration_ms <= MAX_DURATION_MS, EBadDuration);
    assert!(target.character_address() != ctx.sender(), ESelfBounty);           // rule 6
    let now_ms = clock.timestamp_ms();
    let bounty = Bounty<T> {
        id: object::new(ctx),
        target: target.key(),
        target_character: object::id(target),
        target_address: target.character_address(),
        placer: ctx.sender(),
        reward: reward.into_balance(),
        placed_at_s: now_ms / 1000,
        expires_at_ms: now_ms + duration_ms, // cannot overflow: now_ms is a real clock and duration is capped
    };
    let bounty_id = object::id(&bounty);
    event::emit(BountyPlacedEvent {
        bounty_id,
        target: bounty.target,
        target_character: bounty.target_character,
        placer: bounty.placer,
        amount,
        coin_type: coin_name<T>(),
        expires_at_ms: bounty.expires_at_ms,
    });
    transfer::share_object(bounty);
    bounty_id
}

// === Collecting ===

/// The pilot who killed the target collects the whole bounty. `killer` is the claimant's own Character and must
/// belong to the wallet sending this transaction. Returns the coins (Sui style): the dApp transfers them to the
/// hunter's wallet in the same transaction, and other contracts can build on a claim (e.g. split it with a fleet).
/// Time is not needed here: the killmail's own timestamp decides (rule 4), and a late killmail is still valid.
public fun claim<T>(config: &BoardConfig, bounty: Bounty<T>, killmail: &Killmail, killer: &Character,
                    ctx: &mut TxContext): Coin<T> {
    assert!(config.version == VERSION, EWrongVersion);                           // rule 9
    assert!(killmail.is_ship_loss(), ENotAShipKill);                             // rule 1
    assert!(killmail.victim_id() == bounty.target, EWrongVictim);                // rule 2
    assert!(killmail.killer_id() == killer.key(), ENotTheKiller);                // rule 3
    assert!(killer.character_address() == ctx.sender(), ENotYourCharacter);      // rule 3
    assert!(killer.key() != bounty.target, ESelfClaim);                          // rule 5: not the target itself
    assert!(killer.character_address() != bounty.target_address, ESelfClaim);   // rule 5: not the target's wallet
    let kill_s = killmail.kill_timestamp();
    assert!(kill_s >= bounty.placed_at_s, EKillBeforeBounty);                    // rule 4
    assert!(kill_s <= bounty.expires_at_ms / 1000, EKillAfterExpiry);            // rule 4 (seconds vs ms)

    let Bounty { id, target, target_character: _, target_address: _, placer: _, reward, placed_at_s: _,
                 expires_at_ms: _ } = bounty;
    let amount = reward.value();
    event::emit(BountyClaimedEvent {
        bounty_id: id.to_inner(),
        target,
        killmail_id: object::id(killmail),
        killer: killer.key(),
        claimant: ctx.sender(),
        amount,
        coin_type: coin_name<T>(),
    });
    id.delete();                                                                 // rule 8: pays once
    coin::from_balance(reward, ctx)
}

// === Refunding (never gated by the config: rule 9) ===

/// Nobody collected: REFUND_GRACE_MS after the expiry, the poster takes the coins back.
public fun refund<T>(bounty: Bounty<T>, clock: &Clock, ctx: &mut TxContext) {
    assert!(bounty.placer == ctx.sender(), ENotThePlacer);                      // rule 7
    assert!(clock.timestamp_ms() > bounty.expires_at_ms + REFUND_GRACE_MS, ENotExpired);
    let Bounty { id, target: _, target_character: _, target_address: _, placer, reward, placed_at_s: _,
                 expires_at_ms: _ } = bounty;
    event::emit(BountyRefundedEvent {
        bounty_id: id.to_inner(),
        placer,
        amount: reward.value(),
        coin_type: coin_name<T>(),
    });
    id.delete();
    transfer::public_transfer(coin::from_balance(reward, ctx), placer);
}

// === Admin (the AdminCap; rule 9) ===

/// Stop or restart NEW bounties (e.g. when the game moves to a new world). Claims and refunds are unaffected.
public fun set_placing_enabled(config: &mut BoardConfig, _admin: &AdminCap, enabled: bool) {
    config.placing_enabled = enabled;
    event::emit(PlacingSwitchedEvent { enabled });
}

/// After publishing an upgrade with a higher VERSION: move the board to it, so the old package's place and claim
/// stop and the new rules apply to every open bounty.
public fun migrate(config: &mut BoardConfig, _admin: &AdminCap) {
    assert!(config.version < VERSION, ENotAnUpgrade);
    config.version = VERSION;
}

// === Read-only views (for the dApp, the companion and tests) ===
public fun target<T>(b: &Bounty<T>): TenantItemId { b.target }
public fun target_character<T>(b: &Bounty<T>): ID { b.target_character }
public fun target_address<T>(b: &Bounty<T>): address { b.target_address }
public fun placer<T>(b: &Bounty<T>): address { b.placer }
public fun reward_value<T>(b: &Bounty<T>): u64 { b.reward.value() }
public fun placed_at_s<T>(b: &Bounty<T>): u64 { b.placed_at_s }
public fun expires_at_ms<T>(b: &Bounty<T>): u64 { b.expires_at_ms }
public fun placing_enabled(config: &BoardConfig): bool { config.placing_enabled }
public fun version(config: &BoardConfig): u64 { config.version }
public fun refund_grace_ms(): u64 { REFUND_GRACE_MS }
public fun min_duration_ms(): u64 { MIN_DURATION_MS }
public fun max_duration_ms(): u64 { MAX_DURATION_MS }

fun coin_name<T>(): ascii::String { type_name::with_defining_ids<T>().into_string() }

// === Test-only helpers ===
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
/// Pretend the board was left on an older version (to test the version gate).
public fun set_version_for_testing(config: &mut BoardConfig, version: u64) { config.version = version; }
