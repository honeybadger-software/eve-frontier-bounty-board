/// Tests for hb_bounty::bounty_board - the Honey Badger Bounty Board.
///
/// HOW TO READ THIS FILE
///   Part 1 (fixture) builds a miniature EVE Frontier world the way CCP's own killmail tests do
///   (world-contracts/contracts/world/tests/killmail/killmail_tests.move @ 324e4a5): the governor publishes the
///   world, ADMIN becomes the game's sponsor, ADMIN creates characters, and ADMIN reports kills with the real
///   world::killmail::create_killmail. Nothing is mocked. `world::test_helpers` cannot be imported by a dependent
///   package, so the few steps it would do are written out here (same approach as hb_refinery's tests).
///   The board itself is published by BOARD_ADMIN (who receives the AdminCap).
///
///   Part 2 (tests) proves one behaviour per test, with a one-line comment saying what it proves in plain English.
///   Tests marked "audit" pin a finding of the independent security audit of 2026-09-25, so it cannot come back.
///
/// TIME: the Sui Clock is in MILLISECONDS; killmail.kill_timestamp is in SECONDS (see killmail.move). T0 = when the
/// bounty is posted.
///
/// RUN:  cd mods\hb_bounty  &&  sui move test
#[test_only]
module hb_bounty::bounty_board_tests;

use std::{string::{String, utf8}, unit_test::assert_eq};
use sui::{clock::{Self, Clock}, coin::{Self, Coin}, event, sui::SUI, test_scenario as ts};
use world::{
    access::{Self, AdminACL},
    character::{Self, Character},
    killmail::{Self, Killmail},
    killmail_registry::{Self, KillmailRegistry},
    object_registry::{Self, ObjectRegistry},
    world::GovernorCap,
};
use hb_bounty::bounty_board::{
    Self, AdminCap, BoardConfig, Bounty, BountyClaimedEvent, BountyPlacedEvent, BountyRefundedEvent,
};

// ===================================================================================
// PART 1 - FIXTURE
// ===================================================================================

// === Wallets ===
const GOVERNOR: address = @0xA;
const ADMIN: address = @0xB; // the game's sponsor: creates characters and reports kills
const BOARD_ADMIN: address = @0xB0A2D; // published the board, holds its AdminCap
const PLACER: address = @0xC0FFEE; // puts the bounty up
const TARGET: address = @0x7A12; // the pilot with the price on their head
const HUNTER: address = @0xBEEF; // the pilot who kills the target
const TRIBEMATE: address = @0xFA11; // a pilot in the TARGET's tribe
const HUNTER2: address = @0xD00D; // another hunter

// === In-game character ids (killmails name characters by these) ===
const PLACER_GAME_ID: u32 = 2112100001;
const TARGET_GAME_ID: u32 = 2112100002;
const HUNTER_GAME_ID: u32 = 2112100003;
const TRIBEMATE_GAME_ID: u32 = 2112100004;
const HUNTER2_GAME_ID: u32 = 2112100005;
const TARGET_ALT_GAME_ID: u32 = 2112100006; // a second character on the TARGET's wallet
const REPORTER_OTHER_TENANT_GAME_ID: u32 = 2112100007;

// === Tribes (1000167 is the Stillness starter tribe 96.7% of pilots are in) ===
const STARTER_TRIBE: u32 = 1000167;
const PLACER_TRIBE: u32 = 100;
const HUNTER_TRIBE: u32 = 300;
const ALT_TRIBE: u32 = 777;

// === Kills ===
const LOSS_SHIP: u8 = 1;
const LOSS_STRUCTURE: u8 = 2;
const SOLAR_SYSTEM: u64 = 30000142;

// === Time (see TIME above) ===
const T0_MS: u64 = 1_790_000_000_000; // the bounty is posted at this moment
const T0_S: u64 = 1_790_000_000;
const HOUR_MS: u64 = 60 * 60 * 1000;
const DAY_MS: u64 = 24 * HOUR_MS;
const DURATION_MS: u64 = 7 * DAY_MS; // the bounty runs for a week

// === Money (SUI has 9 decimals; the amounts are just distinct numbers) ===
const REWARD: u64 = 5_000_000_000;
const REWARD2: u64 = 1_250_000_000;

/// A second coin type, standing in for the game's EVE token: the board works with any coin.
public struct TEST_EVE has drop {}

public struct Pilots has copy, drop {
    placer: ID,
    target: ID,
    hunter: ID,
    tribemate: ID,
    hunter2: ID,
    target_alt: ID,
    other_tenant_reporter: ID,
}

fun tenant(): String { utf8(b"stillness") }

/// Publishes the world modules the board touches, makes ADMIN the game's sponsor, and publishes the board.
fun setup_world(ts: &mut ts::Scenario) {
    ts::next_tx(ts, GOVERNOR);
    {
        world::world::init_for_testing(ts.ctx());
        access::init_for_testing(ts.ctx());
        object_registry::init_for_testing(ts.ctx());
        killmail_registry::init_for_testing(ts.ctx());
    };
    ts::next_tx(ts, GOVERNOR);
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(ts);
        let mut admin_acl = ts::take_shared<AdminACL>(ts);
        access::add_sponsor_to_acl(&mut admin_acl, &gov_cap, ADMIN);
        ts::return_to_sender(ts, gov_cap);
        ts::return_shared(admin_acl);
    };
    ts::next_tx(ts, BOARD_ADMIN);
    bounty_board::init_for_testing(ts.ctx());
}

/// Creates and shares a Character, exactly as the game does.
fun create_character(ts: &mut ts::Scenario, wallet: address, game_id: u32, tribe: u32, tenant_name: String): ID {
    ts::next_tx(ts, ADMIN);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = character::create_character(
        &mut registry,
        &admin_acl,
        game_id,
        tenant_name,
        tribe,
        wallet,
        utf8(b"pilot"),
        ts.ctx(),
    );
    let id = object::id(&character);
    character.share_character(&admin_acl, ts.ctx());
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    id
}

fun setup(ts: &mut ts::Scenario): Pilots {
    setup_world(ts);
    Pilots {
        placer: create_character(ts, PLACER, PLACER_GAME_ID, PLACER_TRIBE, tenant()),
        target: create_character(ts, TARGET, TARGET_GAME_ID, STARTER_TRIBE, tenant()),
        hunter: create_character(ts, HUNTER, HUNTER_GAME_ID, HUNTER_TRIBE, tenant()),
        tribemate: create_character(ts, TRIBEMATE, TRIBEMATE_GAME_ID, STARTER_TRIBE, tenant()),
        hunter2: create_character(ts, HUNTER2, HUNTER2_GAME_ID, HUNTER_TRIBE, tenant()),
        target_alt: create_character(ts, TARGET, TARGET_ALT_GAME_ID, ALT_TRIBE, tenant()),
        other_tenant_reporter: create_character(ts, HUNTER, REPORTER_OTHER_TENANT_GAME_ID, HUNTER_TRIBE,
                                                utf8(b"liminality")),
    }
}

/// A clock set to `ms` (the real Clock is the shared object 0x6; in tests each transaction makes its own).
fun clock_at(ts: &mut ts::Scenario, ms: u64): Clock {
    let mut c = clock::create_for_testing(ts.ctx());
    c.set_for_testing(ms);
    c
}

/// PLACER puts `amount` of coin T on the TARGET's head for `duration_ms`, at time T0. Returns the bounty's id.
fun place_for<T>(ts: &mut ts::Scenario, p: &Pilots, amount: u64, duration_ms: u64): ID {
    ts::next_tx(ts, PLACER);
    let config = ts::take_shared<BoardConfig>(ts);
    let target = ts::take_shared_by_id<Character>(ts, p.target);
    let c = clock_at(ts, T0_MS);
    let reward = coin::mint_for_testing<T>(amount, ts.ctx());
    let id = bounty_board::place(&config, &target, reward, duration_ms, &c, ts.ctx());
    c.destroy_for_testing();
    ts::return_shared(target);
    ts::return_shared(config);
    id
}

fun place<T>(ts: &mut ts::Scenario, p: &Pilots, amount: u64): ID { place_for<T>(ts, p, amount, DURATION_MS) }

/// The game reports a kill (as the game does, via its sponsor ADMIN), with `reporter` as the reporting character
/// (its tenant becomes the killmail's tenant). Returns the Killmail's object id.
fun report_kill_by(ts: &mut ts::Scenario, reporter: ID, killmail_item_id: u64, killer_game_id: u32,
                   victim_game_id: u32, kill_time_s: u64, loss: u8): ID {
    ts::next_tx(ts, ADMIN);
    let mut registry = ts::take_shared<KillmailRegistry>(ts);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let reporter_char = ts::take_shared_by_id<Character>(ts, reporter);
    killmail::create_killmail(
        &mut registry,
        &admin_acl,
        killmail_item_id,
        killer_game_id as u64,
        victim_game_id as u64,
        &reporter_char,
        kill_time_s,
        loss,
        SOLAR_SYSTEM,
        ts.ctx(),
    );
    ts::return_shared(reporter_char);
    ts::return_shared(admin_acl);
    ts::return_shared(registry);
    ts::next_tx(ts, ADMIN);
    let km = ts::take_shared<Killmail>(ts);  // the newest shared Killmail
    let id = object::id(&km);
    ts::return_shared(km);
    id
}

fun report_kill(ts: &mut ts::Scenario, p: &Pilots, killmail_item_id: u64, killer_game_id: u32,
                victim_game_id: u32, kill_time_s: u64, loss: u8): ID {
    report_kill_by(ts, p.hunter, killmail_item_id, killer_game_id, victim_game_id, kill_time_s, loss)
}

/// `sender` claims bounty `bounty_id` with killmail `km_id`, presenting character `claimant`. A claim needs no
/// clock: the killmail's own time decides. The coins go to the sender's wallet, as the dApp does it.
fun claim<T>(ts: &mut ts::Scenario, sender: address, bounty_id: ID, km_id: ID, claimant: ID) {
    ts::next_tx(ts, sender);
    let config = ts::take_shared<BoardConfig>(ts);
    let bounty = ts::take_shared_by_id<Bounty<T>>(ts, bounty_id);
    let km = ts::take_shared_by_id<Killmail>(ts, km_id);
    let killer = ts::take_shared_by_id<Character>(ts, claimant);
    let paid = bounty_board::claim(&config, bounty, &km, &killer, ts.ctx());
    transfer::public_transfer(paid, sender);
    ts::return_shared(killer);
    ts::return_shared(km);
    ts::return_shared(config);
}

/// `sender` asks for a refund of `bounty_id` at time `now_ms`.
fun refund<T>(ts: &mut ts::Scenario, sender: address, bounty_id: ID, now_ms: u64) {
    ts::next_tx(ts, sender);
    let bounty = ts::take_shared_by_id<Bounty<T>>(ts, bounty_id);
    let c = clock_at(ts, now_ms);
    bounty_board::refund(bounty, &c, ts.ctx());
    c.destroy_for_testing();
}

/// The total of every Coin<T> `who` owns (checked in a fresh transaction so transfers have landed).
fun owned_total<T>(ts: &mut ts::Scenario, who: address): u64 {
    ts::next_tx(ts, who);
    let ids = ts::ids_for_sender<Coin<T>>(ts);
    let mut total = 0;
    let mut i = 0;
    while (i < ids.length()) {
        let c = ts::take_from_sender_by_id<Coin<T>>(ts, ids[i]);
        total = total + c.value();
        ts::return_to_sender(ts, c);
        i = i + 1;
    };
    total
}

fun set_placing(ts: &mut ts::Scenario, enabled: bool) {
    ts::next_tx(ts, BOARD_ADMIN);
    let mut config = ts::take_shared<BoardConfig>(ts);
    let cap = ts::take_from_sender<AdminCap>(ts);
    bounty_board::set_placing_enabled(&mut config, &cap, enabled);
    ts::return_to_sender(ts, cap);
    ts::return_shared(config);
}

fun set_version(ts: &mut ts::Scenario, version: u64) {
    ts::next_tx(ts, BOARD_ADMIN);
    let mut config = ts::take_shared<BoardConfig>(ts);
    bounty_board::set_version_for_testing(&mut config, version);
    ts::return_shared(config);
}

// ===================================================================================
// PART 2 - TESTS
// ===================================================================================

// --- The happy paths ---

#[test]
/// The whole happy path: a bounty is posted, the hunter kills the target, the hunter collects every coin, and the
/// bounty object is gone.
fun test_hunter_collects_the_bounty() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill(&mut ts, &p, 9001, HUNTER_GAME_ID, TARGET_GAME_ID, T0_S + 3600, LOSS_SHIP);
    claim<SUI>(&mut ts, HUNTER, b, km, p.hunter);
    assert_eq!(owned_total<SUI>(&mut ts, HUNTER), REWARD);
    ts::next_tx(&mut ts, HUNTER);
    assert!(!ts::has_most_recent_shared<Bounty<SUI>>(), 0); // claimed bounties are deleted
    ts::end(ts);
}

#[test]
/// Posting records who, how much and until when, and says so in an event the companion can read.
fun test_placing_records_the_bounty_and_emits_an_event() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    ts::next_tx(&mut ts, PLACER);
    let config = ts::take_shared<BoardConfig>(&ts);
    let target = ts::take_shared_by_id<Character>(&ts, p.target);
    let c = clock_at(&mut ts, T0_MS);
    let reward = coin::mint_for_testing<SUI>(REWARD, ts.ctx());
    bounty_board::place(&config, &target, reward, DURATION_MS, &c, ts.ctx());
    assert_eq!(event::events_by_type<BountyPlacedEvent>().length(), 1);
    c.destroy_for_testing();
    ts::return_shared(target);
    ts::return_shared(config);
    ts::next_tx(&mut ts, PLACER);
    let bounty = ts::take_shared<Bounty<SUI>>(&ts);
    assert_eq!(bounty.reward_value(), REWARD);
    assert_eq!(bounty.placer(), PLACER);
    assert_eq!(bounty.target_character(), p.target);
    assert_eq!(bounty.target_address(), TARGET);
    assert_eq!(bounty.expires_at_ms(), T0_MS + DURATION_MS);
    assert_eq!(bounty.placed_at_s(), T0_S);
    ts::return_shared(bounty);
    ts::end(ts);
}

#[test]
/// The board takes any coin: here a stand-in for the game's EVE token.
fun test_any_coin_works() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<TEST_EVE>(&mut ts, &p, REWARD2);
    let km = report_kill(&mut ts, &p, 9002, HUNTER_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_SHIP);
    claim<TEST_EVE>(&mut ts, HUNTER, b, km, p.hunter);
    assert_eq!(owned_total<TEST_EVE>(&mut ts, HUNTER), REWARD2);
    ts::end(ts);
}

#[test]
/// Two bounties on the same pilot are both paid by one kill (bounties stack).
fun test_one_kill_collects_every_bounty_on_the_target() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b1 = place<SUI>(&mut ts, &p, REWARD);
    let b2 = place<SUI>(&mut ts, &p, REWARD2);
    let km = report_kill(&mut ts, &p, 9003, HUNTER_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_SHIP);
    claim<SUI>(&mut ts, HUNTER, b1, km, p.hunter);
    claim<SUI>(&mut ts, HUNTER, b2, km, p.hunter);
    assert_eq!(owned_total<SUI>(&mut ts, HUNTER), REWARD + REWARD2);
    ts::end(ts);
}

#[test]
/// A claim emits an event naming the killmail, the killer and the amount, and returns exactly the reward.
fun test_claim_emits_an_event() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill(&mut ts, &p, 9004, HUNTER_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_SHIP);
    ts::next_tx(&mut ts, HUNTER);
    let config = ts::take_shared<BoardConfig>(&ts);
    let bounty = ts::take_shared_by_id<Bounty<SUI>>(&ts, b);
    let kmo = ts::take_shared_by_id<Killmail>(&ts, km);
    let killer = ts::take_shared_by_id<Character>(&ts, p.hunter);
    let paid = bounty_board::claim(&config, bounty, &kmo, &killer, ts.ctx());
    assert_eq!(event::events_by_type<BountyClaimedEvent>().length(), 1);
    assert_eq!(paid.value(), REWARD);
    transfer::public_transfer(paid, HUNTER);
    ts::return_shared(killer);
    ts::return_shared(kmo);
    ts::return_shared(config);
    ts::end(ts);
}

#[test]
/// audit: pilots in the same tribe can hunt each other. 96.7% of Stillness pilots share the starter tribe, so a
/// tribe rule would have refused about 40% of honest kills.
fun test_a_pilot_in_the_targets_tribe_can_collect() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill(&mut ts, &p, 9012, TRIBEMATE_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_SHIP);
    claim<SUI>(&mut ts, TRIBEMATE, b, km, p.tribemate);
    assert_eq!(owned_total<SUI>(&mut ts, TRIBEMATE), REWARD);
    ts::end(ts);
}

// --- Time ---

#[test]
/// audit (boundary): a kill in the very second the bounty was posted counts.
fun test_a_kill_in_the_posting_second_counts() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill(&mut ts, &p, 9020, HUNTER_GAME_ID, TARGET_GAME_ID, T0_S, LOSS_SHIP);
    claim<SUI>(&mut ts, HUNTER, b, km, p.hunter);
    assert_eq!(owned_total<SUI>(&mut ts, HUNTER), REWARD);
    ts::end(ts);
}

#[test]
/// A kill in the last second before expiry counts.
fun test_a_kill_at_the_deadline_counts() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill(&mut ts, &p, 9011, HUNTER_GAME_ID, TARGET_GAME_ID, (T0_MS + DURATION_MS) / 1000, LOSS_SHIP);
    claim<SUI>(&mut ts, HUNTER, b, km, p.hunter);
    assert_eq!(owned_total<SUI>(&mut ts, HUNTER), REWARD);
    ts::end(ts);
}

#[test]
/// audit: killmails reach the chain late (sometimes days). A deadline kill whose killmail lands 6 days after the
/// expiry is still paid, because the placer cannot refund during the 7-day grace.
fun test_a_late_killmail_still_pays() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    // Six days after expiry the placer tries to refund: refused (checked in its own test), so the bounty is still
    // there when the game finally writes the killmail for a kill one minute before the deadline.
    let km = report_kill(&mut ts, &p, 9021, HUNTER_GAME_ID, TARGET_GAME_ID, (T0_MS + DURATION_MS) / 1000 - 60, LOSS_SHIP);
    claim<SUI>(&mut ts, HUNTER, b, km, p.hunter);
    assert_eq!(owned_total<SUI>(&mut ts, HUNTER), REWARD);
    assert_eq!(bounty_board::refund_grace_ms(), 7 * DAY_MS);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::EKillBeforeBounty)]
/// A kill from before the bounty was posted cannot be cashed in afterwards.
fun test_old_kills_do_not_count() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let km = report_kill(&mut ts, &p, 9009, HUNTER_GAME_ID, TARGET_GAME_ID, T0_S - 1, LOSS_SHIP);
    let b = place<SUI>(&mut ts, &p, REWARD);
    claim<SUI>(&mut ts, HUNTER, b, km, p.hunter);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::EKillAfterExpiry)]
/// A kill after the bounty ran out does not count.
fun test_kills_after_expiry_do_not_count() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill(&mut ts, &p, 9010, HUNTER_GAME_ID, TARGET_GAME_ID, (T0_MS + DURATION_MS) / 1000 + 1, LOSS_SHIP);
    claim<SUI>(&mut ts, HUNTER, b, km, p.hunter);
    ts::end(ts);
}

#[test]
/// audit (boundary): exactly 1 hour and exactly 14 days are both accepted.
fun test_the_shortest_and_longest_durations_are_accepted() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    place_for<SUI>(&mut ts, &p, REWARD, bounty_board::min_duration_ms());
    place_for<SUI>(&mut ts, &p, REWARD, bounty_board::max_duration_ms());
    assert_eq!(bounty_board::max_duration_ms(), 14 * DAY_MS);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::EBadDuration)]
/// A bounty shorter than an hour is refused (too short to be hunted).
fun test_too_short_is_refused() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    place_for<SUI>(&mut ts, &p, REWARD, bounty_board::min_duration_ms() - 1);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::EBadDuration)]
/// A bounty longer than 14 days is refused (coins would sit locked for too long).
fun test_too_long_is_refused() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    place_for<SUI>(&mut ts, &p, REWARD, bounty_board::max_duration_ms() + 1);
    ts::end(ts);
}

// --- Who may collect ---

#[test, expected_failure(abort_code = bounty_board::EZeroReward)]
/// An empty bounty is refused.
fun test_zero_reward_is_refused() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    place<SUI>(&mut ts, &p, 0);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::ENotAShipKill)]
/// Destroying the target's structure does not count: the bounty is on the pilot's ship.
fun test_structure_kill_does_not_count() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill(&mut ts, &p, 9005, HUNTER_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_STRUCTURE);
    claim<SUI>(&mut ts, HUNTER, b, km, p.hunter);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::EWrongVictim)]
/// Killing somebody else does not collect the target's bounty.
fun test_wrong_victim_does_not_count() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill(&mut ts, &p, 9006, HUNTER_GAME_ID, PLACER_GAME_ID, T0_S + 60, LOSS_SHIP);
    claim<SUI>(&mut ts, HUNTER, b, km, p.hunter);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::EWrongVictim)]
/// audit: a killmail from another game tenant with the same pilot number is a different pilot.
fun test_a_killmail_from_another_tenant_does_not_count() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill_by(&mut ts, p.other_tenant_reporter, 9022, HUNTER_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_SHIP);
    claim<SUI>(&mut ts, HUNTER, b, km, p.hunter);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::ENotTheKiller)]
/// Only the pilot the killmail names as the killer can collect, not a bystander holding the same killmail.
fun test_only_the_killer_can_collect() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill(&mut ts, &p, 9007, HUNTER_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_SHIP);
    claim<SUI>(&mut ts, HUNTER2, b, km, p.hunter2);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::ENotYourCharacter)]
/// Presenting the real killer's character from a different wallet is refused.
fun test_someone_elses_character_is_refused() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill(&mut ts, &p, 9008, HUNTER_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_SHIP);
    claim<SUI>(&mut ts, HUNTER2, b, km, p.hunter);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::ESelfClaim)]
/// audit: the game records ship losses where killer and victim are the same pilot (10 on Stillness). The target
/// cannot cash in their own death, even after changing tribe.
fun test_the_target_cannot_collect_their_own_death() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    ts::next_tx(&mut ts, ADMIN);  // the target leaves the starter tribe
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let mut target = ts::take_shared_by_id<Character>(&ts, p.target);
        character::update_tribe(&mut target, &admin_acl, ALT_TRIBE, ts.ctx());
        ts::return_shared(target);
        ts::return_shared(admin_acl);
    };
    let km = report_kill(&mut ts, &p, 9023, TARGET_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_SHIP);
    claim<SUI>(&mut ts, TARGET, b, km, p.target);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::ESelfClaim)]
/// The target cannot cash in their own death even after the game moves their character to a new wallet (the
/// wallet check alone would miss this; found by the mutation check).
fun test_the_target_cannot_collect_their_own_death_from_a_new_wallet() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let new_wallet = @0x7A12_0002;
    ts::next_tx(&mut ts, ADMIN);
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let mut target = ts::take_shared_by_id<Character>(&ts, p.target);
        character::update_address(&mut target, &admin_acl, new_wallet, ts.ctx());
        ts::return_shared(target);
        ts::return_shared(admin_acl);
    };
    let km = report_kill(&mut ts, &p, 9025, TARGET_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_SHIP);
    claim<SUI>(&mut ts, new_wallet, b, km, p.target);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::ESelfClaim)]
/// audit: another character on the target's own wallet cannot collect (884 Stillness wallets own several).
fun test_the_targets_other_character_cannot_collect() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill(&mut ts, &p, 9024, TARGET_ALT_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_SHIP);
    claim<SUI>(&mut ts, TARGET, b, km, p.target_alt);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::ESelfBounty)]
/// You cannot put a bounty on yourself (it could only be used to move money to a friend who "kills" you).
fun test_no_bounty_on_yourself() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    ts::next_tx(&mut ts, TARGET);
    let config = ts::take_shared<BoardConfig>(&ts);
    let target = ts::take_shared_by_id<Character>(&ts, p.target);
    let c = clock_at(&mut ts, T0_MS);
    let reward = coin::mint_for_testing<SUI>(REWARD, ts.ctx());
    bounty_board::place(&config, &target, reward, DURATION_MS, &c, ts.ctx());
    abort 99
}

// --- Refunds ---

#[test]
/// Nobody collected: after the deadline and the 7-day grace, the placer gets every coin back.
fun test_placer_is_refunded_after_the_grace() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    ts::next_tx(&mut ts, PLACER);
    let bounty = ts::take_shared_by_id<Bounty<SUI>>(&ts, b);
    let c = clock_at(&mut ts, T0_MS + DURATION_MS + bounty_board::refund_grace_ms() + 1);
    bounty_board::refund(bounty, &c, ts.ctx());
    assert_eq!(event::events_by_type<BountyRefundedEvent>().length(), 1);
    c.destroy_for_testing();
    assert_eq!(owned_total<SUI>(&mut ts, PLACER), REWARD);
    ts::next_tx(&mut ts, PLACER);
    assert!(!ts::has_most_recent_shared<Bounty<SUI>>(), 0);
    ts::end(ts);
}

#[test]
/// Refunds work for any coin, not just SUI (every Coin<T> has `store`, so it can always be sent back).
fun test_refund_works_for_any_coin() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<TEST_EVE>(&mut ts, &p, REWARD2);
    refund<TEST_EVE>(&mut ts, PLACER, b, T0_MS + DURATION_MS + bounty_board::refund_grace_ms() + 1);
    assert_eq!(owned_total<TEST_EVE>(&mut ts, PLACER), REWARD2);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::ENotExpired)]
/// audit: six days after expiry the placer still cannot pull the money back (a killmail may be on its way).
fun test_no_refund_during_the_grace() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    refund<SUI>(&mut ts, PLACER, b, T0_MS + DURATION_MS + 6 * DAY_MS);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::ENotExpired)]
/// The last millisecond of the grace still refuses a refund.
fun test_no_refund_at_the_end_of_the_grace() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    refund<SUI>(&mut ts, PLACER, b, T0_MS + DURATION_MS + bounty_board::refund_grace_ms());
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::ENotThePlacer)]
/// Only the placer can take an expired bounty back.
fun test_only_the_placer_gets_a_refund() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    refund<SUI>(&mut ts, HUNTER, b, T0_MS + DURATION_MS + bounty_board::refund_grace_ms() + 1);
    ts::end(ts);
}

// --- The board switch and the version (rule 9) ---

#[test, expected_failure(abort_code = bounty_board::EPlacingClosed)]
/// When the admin closes the board (e.g. the game moved to a new world), no new bounty can be posted.
fun test_a_closed_board_takes_no_new_bounties() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    set_placing(&mut ts, false);
    place<SUI>(&mut ts, &p, REWARD);
    ts::end(ts);
}

#[test]
/// Closing the board never touches bounties already posted: they can still be claimed and refunded.
fun test_closing_the_board_keeps_claims_and_refunds_working() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b1 = place<SUI>(&mut ts, &p, REWARD);
    let b2 = place<SUI>(&mut ts, &p, REWARD2);
    set_placing(&mut ts, false);
    let km = report_kill(&mut ts, &p, 9030, HUNTER_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_SHIP);
    claim<SUI>(&mut ts, HUNTER, b1, km, p.hunter);
    refund<SUI>(&mut ts, PLACER, b2, T0_MS + DURATION_MS + bounty_board::refund_grace_ms() + 1);
    assert_eq!(owned_total<SUI>(&mut ts, HUNTER), REWARD);
    assert_eq!(owned_total<SUI>(&mut ts, PLACER), REWARD2);
    set_placing(&mut ts, true);  // and it can be reopened
    place<SUI>(&mut ts, &p, REWARD);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::EWrongVersion)]
/// A board on another version refuses posting (the old package cannot keep taking bounties after an upgrade).
fun test_a_version_mismatch_stops_posting() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    set_version(&mut ts, 2);
    place<SUI>(&mut ts, &p, REWARD);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::EWrongVersion)]
/// A board on another version refuses claims through this package (the new rules apply to open bounties).
fun test_a_version_mismatch_stops_claims() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    let km = report_kill(&mut ts, &p, 9031, HUNTER_GAME_ID, TARGET_GAME_ID, T0_S + 60, LOSS_SHIP);
    set_version(&mut ts, 2);
    claim<SUI>(&mut ts, HUNTER, b, km, p.hunter);
    ts::end(ts);
}

#[test]
/// Refunds never check the version or the switch: nobody, not even the admin, can freeze a placer's coins.
fun test_refunds_ignore_the_version() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    let b = place<SUI>(&mut ts, &p, REWARD);
    set_version(&mut ts, 2);
    set_placing(&mut ts, false);
    refund<SUI>(&mut ts, PLACER, b, T0_MS + DURATION_MS + bounty_board::refund_grace_ms() + 1);
    assert_eq!(owned_total<SUI>(&mut ts, PLACER), REWARD);
    ts::end(ts);
}

#[test]
/// After an upgrade (the board left on an older version), the admin migrates it to this version.
fun test_migrate_moves_an_older_board_forward() {
    let mut ts = ts::begin(GOVERNOR);
    let p = setup(&mut ts);
    set_version(&mut ts, 0);
    ts::next_tx(&mut ts, BOARD_ADMIN);
    {
        let mut config = ts::take_shared<BoardConfig>(&ts);
        let cap = ts::take_from_sender<AdminCap>(&ts);
        bounty_board::migrate(&mut config, &cap);
        assert_eq!(config.version(), 1);
        ts::return_to_sender(&ts, cap);
        ts::return_shared(config);
    };
    place<SUI>(&mut ts, &p, REWARD);
    ts::end(ts);
}

#[test, expected_failure(abort_code = bounty_board::ENotAnUpgrade)]
/// Migrating a board that is already current is refused.
fun test_migrate_refuses_a_current_board() {
    let mut ts = ts::begin(GOVERNOR);
    setup(&mut ts);
    ts::next_tx(&mut ts, BOARD_ADMIN);
    let mut config = ts::take_shared<BoardConfig>(&ts);
    let cap = ts::take_from_sender<AdminCap>(&ts);
    bounty_board::migrate(&mut config, &cap);
    abort 99
}

#[test]
/// The publisher receives the AdminCap and the board starts open, on version 1.
fun test_publishing_opens_the_board_and_hands_over_the_admin_cap() {
    let mut ts = ts::begin(GOVERNOR);
    setup(&mut ts);
    ts::next_tx(&mut ts, BOARD_ADMIN);
    assert!(ts::has_most_recent_for_sender<AdminCap>(&ts), 0);
    let config = ts::take_shared<BoardConfig>(&ts);
    assert!(config.placing_enabled(), 1);
    assert_eq!(config.version(), 1);
    ts::return_shared(config);
    ts::end(ts);
}
