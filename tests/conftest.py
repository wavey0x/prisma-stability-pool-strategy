import pytest
from ape import Contract, project
from ape.utils import ZERO_ADDRESS


############ CONFIG FIXTURES ############

# Adjust the string based on the `asset` your strategy will use
# You may need to add the token address to `tokens` fixture.
@pytest.fixture(scope="session")
def asset(tokens):
    yield Contract(tokens["mkusd"])

# Adjust the amount that should be used for testing based on `asset`.
@pytest.fixture(scope="session")
def amount(asset, user, whale):
    amount = 100_000 * 10 ** asset.decimals()

    asset.transfer(user, amount, sender=whale)
    yield amount


############ STANDARD FIXTURES ############


@pytest.fixture(scope="session")
def daddy(accounts):
    yield accounts["0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52"]


@pytest.fixture(scope="session")
def user(accounts):
    yield accounts[0]


@pytest.fixture(scope="session")
def rewards(accounts):
    yield accounts[1]


@pytest.fixture(scope="session")
def management(accounts):
    yield accounts[2]


@pytest.fixture(scope="session")
def keeper(accounts):
    yield accounts[3]


@pytest.fixture(scope="session")
def tokens():
    tokens = {
        "weth": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "dai": "0x6B175474E89094C44Da98b954EedeAC495271d0F",
        "usdc": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        "mkusd": "0x4591DBfF62656E7859Afe5e45f6f47D3669fBB28",
    }
    yield tokens


@pytest.fixture(scope="session")
def whale(accounts, asset, user):
    # Prisma Fee receiver
    w = accounts["0xfdCE0267803C6a0D209D3721d2f01Fd618e9CBF8"]
    asset.transfer(user, 1_000_000 * 10 ** 18, sender=w)
    yield w

@pytest.fixture(scope="session")
def weth(tokens):
    yield Contract(tokens["weth"])


@pytest.fixture(scope="session")
def weth_amount(user, weth):
    weth_amount = 10 ** weth.decimals()
    user.transfer(weth, weth_amount)
    yield weth_amount


@pytest.fixture(scope="session")
def factory(strategy):
    yield Contract(strategy.FACTORY())

@pytest.fixture(scope="session")
def gov(accounts):
    yield accounts['0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52']

@pytest.fixture(scope="session")
def set_protocol_fee(factory):
    def set_protocol_fee(protocol_fee=0):
        owner = factory.governance()
        factory.set_protocol_fee_recipient(owner, sender=owner)
        factory.set_protocol_fee_bps(protocol_fee, sender=owner)

    yield set_protocol_fee

@pytest.fixture(scope="session")
def prisma_factory():
    yield Contract('0x70b66E20766b775B2E9cE5B718bbD285Af59b7E1')

@pytest.fixture(scope="session")
def prisma_vault():
    yield Contract('0x06bDF212C290473dCACea9793890C5024c7Eb02c')

@pytest.fixture(scope="session")
def price_feed():
    yield Contract('0xC105CeAcAeD23cad3E9607666FEF0b773BC86aac')

@pytest.fixture(scope="session")
def liquidation_manager():
    yield Contract('0x5de309dfd7f94e9e2A18Cb6bA61CA305aBF8e9E2')

@pytest.fixture(scope="session")
def stability_pool():
    yield Contract('0xed8B26D99834540C5013701bB3715faFD39993Ba')

@pytest.fixture(scope="session")
def yprisma():
    yield Contract('0xe3668873D944E4A949DA05fc8bDE419eFF543882')

@pytest.fixture(scope="session")
def whales(accounts, user, system_collaterals,liquidation_manager):
    whales = [
        accounts['0x0B925eD163218f6662a35e0f0371Ac234f9E9371'], # wsteth
        accounts['0x1BeE69b7dFFfA4E2d53C2a2Df135C388AD25dCD2'], # reth
        accounts['0xED1F7bb04D2BA2b6EbE087026F03C96Ea2c357A8'], # cbeth
        accounts['0x78bB3aEC3d855431bd9289fD98dA13F9ebB7ef15'], # sfrxeth
    ]

    for whale, collat in zip(whales,system_collaterals):
        c = Contract(collat)
        c.transfer(liquidation_manager, 100 * 10 ** 18, sender=whale)

    yield whales

@pytest.fixture(scope="session")
def create_strategy(management, keeper, asset, rewards, prisma_vault, prisma_factory, stability_pool, price_feed, gov):
    def create_strategy(asset, performanceFee=1_000):
        strategy = management.deploy(
            project.Strategy, 
            asset, 
            "PrismaStabilityPoolFarmer",
            prisma_factory,
            stability_pool,
            prisma_vault,
            price_feed,
            100, # discount
            gov, 
        )
        strategy = project.IStrategyInterface.at(strategy.address)

        strategy.setKeeper(keeper, sender=management)
        strategy.setPerformanceFeeRecipient(rewards, sender=management)
        strategy.setPerformanceFee(performanceFee, sender=management)

        return strategy

    yield create_strategy


@pytest.fixture(scope="session")
def create_oracle(management):
    def create_oracle(_management=management):
        oracle = _management.deploy(project.StrategyAprOracle)

        return oracle

    yield create_oracle


@pytest.fixture(scope="session")
def strategy(asset, create_strategy):
    strategy = create_strategy(asset)

    yield strategy

@pytest.fixture(scope="session")
def oracle(create_oracle):
    oracle = create_oracle()

    yield oracle


############ HELPER FUNCTIONS ############


@pytest.fixture(scope="session")
def deposit(strategy, asset, user, amount):
    def deposit(_strategy=strategy, _asset=asset, assets=amount, account=user):
        _asset.approve(_strategy, assets, sender=account)
        _strategy.deposit(assets, account, sender=account)

    yield deposit

@pytest.fixture(scope="session")
def system_collaterals(prisma_factory):
    count = prisma_factory.troveManagerCount()
    collaterals = []
    for i in range (0, count):
        tm = prisma_factory.troveManagers(i)
        if tm == ZERO_ADDRESS:
            break
        c = Contract(Contract(tm).collateralToken())
        if c.address not in collaterals:
            collaterals.append(c.address)
    return collaterals

@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5

@pytest.fixture(scope="function")
def simulate_liquidations(
    accounts,
    system_collaterals, 
    liquidation_manager,
    whales,
    stability_pool,
):
    def simulate_liquidations():
        lm = accounts[liquidation_manager.address]
        lm.balance += 10 ** 18
        debt_amount = 3_000 * 10 ** 18
        collat_amount = 10 ** 18
        for collat in system_collaterals:
            c = Contract(collat)
            c.transfer(stability_pool, collat_amount, sender=lm)
            stability_pool.offset(collat, debt_amount, collat_amount, sender=lm)
    
    yield simulate_liquidations