// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script, console2} from 'forge-std/Script.sol';
import {ERC20} from 'openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';
import {IPoolConfigurator} from '../src/contracts/interfaces/IPoolConfigurator.sol';
import {IPoolDataProvider} from '../src/contracts/interfaces/IPoolDataProvider.sol';
import {ConfiguratorInputTypes} from '../src/contracts/protocol/libraries/types/ConfiguratorInputTypes.sol';
import {IDefaultInterestRateStrategyV2} from '../src/contracts/misc/DefaultReserveInterestRateStrategyV2.sol';

contract PublicMintERC20 is ERC20 {
  uint8 private _decimals;

  constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
    _decimals = decimals_;
  }

  function mint(address to, uint256 amount) public {
    _mint(to, amount);
  }

  function decimals() public view virtual override returns (uint8) {
    return _decimals;
  }
}

contract DeployTestReserve is Script {
  // Deployment addresses
  address constant POOL_CONFIGURATOR = 0x303f168181Bc1b648ba9Dcd9090be6a6786e675C;
  address constant POOL_DATA_PROVIDER = 0xE1A6Cda0403685776586c9bDC820e37fC46E53fA;
  address constant ATOKEN_IMPL = 0x975a715749e530c02184091b4fFb47ccd3e86293;
  address constant VARIABLE_DEBT_IMPL = 0x0624FbC8aC1F60F3aB16C79AF6A2150242d0d778;
  address constant RATE_STRATEGY = 0xe7Ab34Fd2e70bd077dD85343f2227F451fA97374;
  address constant TREASURY = 0xfea2dF483c3aa8f0A33bb96339E3fc220010D3f0;

  function run() external {
    vm.startBroadcast();

    // Deploy test token
    PublicMintERC20 testToken = new PublicMintERC20('phylTest', 'PHYLTEST', 8);
    console2.log('Test Token deployed at:', address(testToken));

    // Mint initial tokens for msg.sender
    uint256 initialMintAmount = 1_000_000 * 10 ** 8; // 1 million tokens with 8 decimals
    testToken.mint(msg.sender, initialMintAmount);
    console2.log('Minted', initialMintAmount, 'tokens to', msg.sender);

    // Initialize reserve
    IPoolConfigurator configurator = IPoolConfigurator(POOL_CONFIGURATOR);
    console2.log('Using Pool Configurator at:', POOL_CONFIGURATOR);

    // Create interest rate data
    bytes memory interestRateData = abi.encode(
      IDefaultInterestRateStrategyV2.InterestRateData({
        optimalUsageRatio: 80_00, // 80%
        baseVariableBorrowRate: 1_00, // 1%
        variableRateSlope1: 4_00, // 4%
        variableRateSlope2: 60_00 // 60%
      })
    );

    ConfiguratorInputTypes.InitReserveInput[]
      memory input = new ConfiguratorInputTypes.InitReserveInput[](1);
    input[0] = ConfiguratorInputTypes.InitReserveInput({
      aTokenImpl: ATOKEN_IMPL,
      variableDebtTokenImpl: VARIABLE_DEBT_IMPL,
      useVirtualBalance: true,
      interestRateStrategyAddress: RATE_STRATEGY,
      underlyingAsset: address(testToken),
      treasury: TREASURY,
      incentivesController: address(0),
      aTokenName: 'Aave Test Token',
      aTokenSymbol: 'aTEST',
      variableDebtTokenName: 'Variable Debt Test',
      variableDebtTokenSymbol: 'vdTEST',
      params: '',
      interestRateData: interestRateData
    });

    configurator.initReserves(input);
    console2.log('Reserve initialized for token:', address(testToken));

    // Configure as collateral
    configurator.configureReserveAsCollateral(
      address(testToken),
      7500, // 75% LTV
      8000, // 80% liquidation threshold
      10500 // 5% liquidation bonus
    );
    console2.log(
      'Reserve configured as collateral with 75% LTV, 80% liquidation threshold, 5% liquidation bonus'
    );

    // Enable borrowing
    configurator.setReserveBorrowing(address(testToken), true);
    console2.log('Borrowing enabled for token:', address(testToken));

    // Get and log the aToken and variable debt token addresses
    IPoolDataProvider dataProvider = IPoolDataProvider(POOL_DATA_PROVIDER);
    (address aToken, , address variableDebtToken) = dataProvider.getReserveTokensAddresses(
      address(testToken)
    );
    console2.log('aToken address:', aToken);
    console2.log('Variable Debt Token address:', variableDebtToken);

    vm.stopBroadcast();
  }
}
