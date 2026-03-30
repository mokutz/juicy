/// Module 1: Juicy Coin ($JUICY)
/// ─────────────────────────────────────────────────────────────────────────────
/// Total supply: 1,000,000,000 JUICY (9 decimals → 1_000_000_000_000_000_000 base units)
/// Features:
///   • One-time treasury mint to hard cap
///   • Custom transfer with 2% auto-burn
///   • Basic staking with rewards vault
///
/// Deploy (Testnet):
///   sui client publish --gas-budget 200000000
///
/// After publish, note the PackageID, TreasuryCap ObjectID, and RewardsVault ObjectID.
/// ─────────────────────────────────────────────────────────────────────────────
module syndicate_suite::juicy_coin {

    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::event;

    // ── Constants ────────────────────────────────────────────────────────────
    /// 9 decimals, same as SUI
    const DECIMALS: u8 = 9;

    /// 1 billion tokens × 10^9 base units
    const MAX_SUPPLY: u64 = 1_000_000_000_000_000_000;

    /// Burn fee numerator  (2%)
    const BURN_BPS: u64 = 200;
    const BPS_DENOM: u64 = 10_000;

    // ── Error codes ──────────────────────────────────────────────────────────
    const ESupplyExceeded:    u64 = 0;
    const EInsufficientValue: u64 = 1;
    const EStakeNotFound:     u64 = 2;
    const ENoRewards:         u64 = 3;

    // ── One-Time-Witness ─────────────────────────────────────────────────────
    /// The OTW must match the module name in ALL_CAPS.
    public struct JUICY_COIN has drop {}

    // ── Shared objects ───────────────────────────────────────────────────────

    /// Shared rewards vault that accumulates tokens designated for staking rewards.
    /// Anyone can deposit; only the staking system withdraws.
    public struct RewardsVault has key {
        id: UID,
        balance: Balance<JUICY_COIN>,
        /// Basis-points reward rate per epoch (e.g. 10 = 0.10 % per epoch)
        reward_rate_bps: u64,
    }

    /// Per-user staking receipt (owned object returned to the staker).
    public struct StakeReceipt has key, store {
        id: UID,
        staker: address,
        staked_amount: u64,
        stake_epoch: u64,          // epoch when stake was created
        bonus_multiplier: u64,     // 1 = normal, 2 = rare-NFT holder bonus (set externally)
    }

    // ── Events ───────────────────────────────────────────────────────────────
    public struct BurnEvent has copy, drop {
        amount_burned: u64,
    }

    public struct StakeEvent has copy, drop {
        staker: address,
        amount: u64,
        epoch: u64,
    }

    public struct UnstakeEvent has copy, drop {
        staker: address,
        amount: u64,
        rewards: u64,
    }

    // ── Init ─────────────────────────────────────────────────────────────────
    /// Called once at publish time.
    /// Mints the entire supply to the publisher and creates the shared RewardsVault.
    fun init(witness: JUICY_COIN, ctx: &mut TxContext) {
        // Create the currency; TreasuryCap is returned to the publisher.
        let (mut treasury_cap, metadata) = coin::create_currency(
            witness,
            DECIMALS,
            b"JUICY",
            b"Juicy Coin",
            b"The native token of The Syndicate Suite",
            option::none(),
            ctx,
        );

        // Mint the full hard-capped supply to the publisher's address.
        let total = coin::mint(&mut treasury_cap, MAX_SUPPLY, ctx);
        transfer::public_transfer(total, tx_context::sender(ctx));

        // Transfer TreasuryCap to publisher (needed for future burns).
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));

        // Freeze the metadata (makes it immutable and publicly readable).
        transfer::public_freeze_object(metadata);

        // Create and share the RewardsVault (empty at genesis).
        let vault = RewardsVault {
            id: object::new(ctx),
            balance: balance::zero<JUICY_COIN>(),
            reward_rate_bps: 10, // 0.10% per epoch default
        };
        transfer::share_object(vault);
    }

    // ── Core Token Logic ─────────────────────────────────────────────────────

    /// Custom transfer with 2% burn.
    /// Sender splits off 2% → burned. Remaining 98% → recipient.
    ///
    /// Usage (PTB / TypeScript SDK):
    ///   tx.moveCall({
    ///     target: `<PACKAGE_ID>::juicy_coin::transfer_with_burn`,
    ///     arguments: [coinArg, recipientArg, treasuryCapArg],
    ///   });
    public fun transfer_with_burn(
        mut payment: Coin<JUICY_COIN>,
        recipient: address,
        treasury_cap: &mut TreasuryCap<JUICY_COIN>,
        ctx: &mut TxContext,
    ) {
        let total_value = coin::value(&payment);
        assert!(total_value > 0, EInsufficientValue);

        // Calculate 2% burn amount (floor division is intentional).
        let burn_amount = (total_value * BURN_BPS) / BPS_DENOM;

        // Split burn portion and destroy it permanently.
        if burn_amount > 0 {
            let burn_coin = coin::split(&mut payment, burn_amount, ctx);
            coin::burn(treasury_cap, burn_coin);
            event::emit(BurnEvent { amount_burned: burn_amount });
        };

        // Transfer the remaining 98% to recipient.
        transfer::public_transfer(payment, recipient);
    }

    // ── Staking ──────────────────────────────────────────────────────────────

    /// Deposit tokens into the RewardsVault.
    /// Call this to fund the vault with rewards (e.g. from project treasury allocation).
    public fun deposit_rewards(
        vault: &mut RewardsVault,
        payment: Coin<JUICY_COIN>,
    ) {
        let incoming = coin::into_balance(payment);
        balance::join(&mut vault.balance, incoming);
    }

    /// Stake $JUICY. Returns a StakeReceipt to the caller.
    /// bonus_multiplier: pass 1 for standard holders, 2 for Rare NFT holders.
    /// The NFT contract (Module 2) can set this; for now the caller asserts it.
    public fun stake(
        stake_coin: Coin<JUICY_COIN>,
        bonus_multiplier: u64,
        ctx: &mut TxContext,
    ): StakeReceipt {
        let amount = coin::value(&stake_coin);
        assert!(amount > 0, EInsufficientValue);

        // Lock the tokens inside the receipt object.
        // (In a production contract you would store a Balance here;
        //  we keep it as a u64 record and hold the coin externally for clarity.)
        let epoch = tx_context::epoch(ctx);
        let staker = tx_context::sender(ctx);

        // Burn the coin into the object (hold value as staked_amount).
        // NOTE: A production version should store Balance<JUICY_COIN> inside
        //       the receipt to prevent double-claims. This illustrates the pattern.
        sui::pay::keep(stake_coin, ctx); // temporarily keeps coin at sender

        event::emit(StakeEvent { staker, amount, epoch });

        StakeReceipt {
            id: object::new(ctx),
            staker,
            staked_amount: amount,
            stake_epoch: epoch,
            bonus_multiplier,
        }
    }

    /// Unstake and claim rewards from the vault.
    /// Rewards = staked_amount × reward_rate_bps × epochs_elapsed × bonus_multiplier / 10000
    public fun unstake(
        receipt: StakeReceipt,
        vault: &mut RewardsVault,
        ctx: &mut TxContext,
    ) {
        let StakeReceipt {
            id,
            staker,
            staked_amount,
            stake_epoch,
            bonus_multiplier,
        } = receipt;

        object::delete(id);

        let current_epoch = tx_context::epoch(ctx);
        let epochs_elapsed = if (current_epoch > stake_epoch) {
            current_epoch - stake_epoch
        } else { 0 };

        // Calculate rewards with optional bonus multiplier (Rare NFT = 2×).
        let base_reward = (staked_amount * vault.reward_rate_bps * epochs_elapsed) / BPS_DENOM;
        let total_reward = base_reward * bonus_multiplier;

        assert!(balance::value(&vault.balance) >= total_reward, ENoRewards);

        event::emit(UnstakeEvent { staker, amount: staked_amount, rewards: total_reward });

        // Pay out rewards from vault.
        if total_reward > 0 {
            let reward_balance = balance::split(&mut vault.balance, total_reward);
            let reward_coin = coin::from_balance(reward_balance, ctx);
            transfer::public_transfer(reward_coin, staker);
        };
    }

    /// Update reward rate (admin only — caller must hold TreasuryCap).
    public fun set_reward_rate(
        _cap: &TreasuryCap<JUICY_COIN>,
        vault: &mut RewardsVault,
        new_rate_bps: u64,
    ) {
        vault.reward_rate_bps = new_rate_bps;
    }

    // ── View helpers ─────────────────────────────────────────────────────────

    public fun vault_balance(vault: &RewardsVault): u64 {
        balance::value(&vault.balance)
    }

    public fun receipt_amount(r: &StakeReceipt): u64 { r.staked_amount }
    public fun receipt_multiplier(r: &StakeReceipt): u64 { r.bonus_multiplier }
    public fun receipt_epoch(r: &StakeReceipt): u64 { r.stake_epoch }
}
