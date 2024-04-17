import ape
from ape import Contract
from utils.constants import MAX_BPS
from utils.checks import check_strategy_totals
from utils.helpers import days_to_secs, increase_time, withdraw_and_check
import pytest

WEEK = 60 * 60 * 24 * 7

def test_collat_sell(
    chain,
    asset,
    strategy,
    deposit,
    user,
    amount,
    whale,
    RELATIVE_APPROX,
    keeper,
    simulate_liquidations,
    management,
    accounts,
    yprisma,
    system_collaterals,
    stability_pool,
):  
    # Deposit to the strategy
    user_balance_before = asset.balanceOf(user)

    # Deposit to the strategy
    # deposit(strategy=strategy.address, asset=asset, user=user, amount=10 ** 25)
    deposit()

    simulate_liquidations()

    indices = strategy.getClaimableIndices()
    print('num indices',len(indices))
    assert len(indices) > 0

    
    # Accrue some rewards
    chain.pending_timestamp += WEEK
    chain.mine()
    strategy.setClaimParams(True, True, sender=management)

    tx = strategy.report(sender=keeper)
    report = list(tx.decode_logs(strategy.Reported))[0]
    assert report.profit == 0
    assert report.loss == 0
    
    # TODO: Add some code to simulate earning yield
    to_airdrop = amount // 100
    asset.transfer(strategy.address, to_airdrop, sender=whale)

    # Harvest 2: Realize profit
    chain.mine(10)

    before_pps = strategy.pricePerShare()

    # needed for profits to unlock
    increase_time(chain, strategy.profitMaxUnlockTime() - 1)

    profit, loss = tx.return_value

    assert profit == 0

    # TODO: Implement logic so total_debt == amount + profit
    print('total debt',strategy.totalDebt()/10**18)
    print('total idle',strategy.totalIdle()/10**18)
    check_strategy_totals(
        strategy, total_assets=amount + profit, total_debt=amount + profit, total_idle=0
    )

    

    # TODO: Implement logic so total_debt == amount + profit]

    print('total debt',strategy.totalDebt()/10**18)
    print('total idle',strategy.totalIdle()/10**18)

    check_strategy_totals(
        strategy, total_assets=amount + profit, total_debt=amount + profit, total_idle=0
    )
    assert strategy.pricePerShare() == before_pps

    # withdrawal
    for coll in system_collaterals:
        coll = Contract(coll)
        amt = coll.balanceOf(strategy)
        print(f'{coll} {amt/10**18:,.2f}')

    # When entire position is withdrawn, collat gains cannot be claimed
    tx = strategy.redeem(amount, user, user, sender=user)

    # Put more in so we can claim
    asset.transfer(strategy.address, to_airdrop, sender=whale)
    tx = stability_pool.provideToSP(to_airdrop, sender=strategy)
    assert asset.balanceOf(user) < user_balance_before


def test__profitable_report__with_fee(
    chain,
    asset,
    strategy,
    deposit,
    user,
    management,
    rewards,
    amount,
    whale,
    factory,
    RELATIVE_APPROX,
    keeper,
):
    # Set performance fee to 10%
    performance_fee = int(1_000)
    strategy.setPerformanceFee(performance_fee, sender=management)

    # Deposit to the strategy
    user_balance_before = asset.balanceOf(user)

    # Deposit to the strategy
    deposit()

    # TODO: Implement logic so total_debt ends > 0
    check_strategy_totals(
        strategy, total_assets=amount, total_debt=amount, total_idle=0
    )

    # TODO: Add some code to simulate earning yield
    to_airdrop = amount // 100

    asset.transfer(strategy.address, to_airdrop, sender=whale)

    chain.mine(10)

    before_pps = strategy.pricePerShare()

    tx = strategy.report(sender=keeper)

    profit, loss = tx.return_value

    assert profit > 0

    (protocol_fee, protocol_fee_recipient) = factory.protocol_fee_config(
        sender=strategy.address
    )

    expected_performance_fee = (
        (profit * performance_fee // MAX_BPS) * (10_000 - protocol_fee) // MAX_BPS
    )

    # TODO: Implement logic so total_debt == amount + profit
    check_strategy_totals(
        strategy, total_assets=amount + profit, total_debt=amount + profit, total_idle=0
    )

    # needed for profits to unlock
    increase_time(chain, strategy.profitMaxUnlockTime() - 1)

    # TODO: Implement logic so total_debt == amount + profit
    check_strategy_totals(
        strategy, total_assets=amount + profit, total_debt=amount + profit, total_idle=0
    )

    assert strategy.pricePerShare() > before_pps

    tx = strategy.redeem(amount, user, user, sender=user)

    assert asset.balanceOf(user) > user_balance_before

    rewards_balance_before = asset.balanceOf(rewards)

    strategy.redeem(expected_performance_fee, rewards, rewards, sender=rewards)

    assert asset.balanceOf(rewards) >= rewards_balance_before + expected_performance_fee


def test__tend_trigger(
    chain,
    strategy,
    asset,
    amount,
    deposit,
    keeper,
    user,
):
    # Check Trigger
    assert strategy.tendTrigger()[0] == False

    # Deposit to the strategy
    deposit()

    # Check Trigger
    assert strategy.tendTrigger()[0] == False

    chain.mine(500)

    # Check Trigger
    assert strategy.tendTrigger()[0] == False

    strategy.report(sender=keeper)

    # Check Trigger
    assert strategy.tendTrigger()[0] == False

    # needed for profits to unlock
    increase_time(chain, strategy.profitMaxUnlockTime() - 1)

    # Check Trigger
    assert strategy.tendTrigger()[0] == False

    strategy.redeem(amount, user, user, sender=user)

    # Check Trigger
    assert strategy.tendTrigger()[0] == False
