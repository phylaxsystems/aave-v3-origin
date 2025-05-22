// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {IPoolAddressesProvider} from '../../src/contracts/interfaces/IPoolAddressesProvider.sol';
import {IAaveOracle} from '../../src/contracts/interfaces/IAaveOracle.sol';
import {IPriceOracleGetter} from '../../src/contracts/interfaces/IPriceOracleGetter.sol';
import {MintableERC20} from '../../src/contracts/mocks/tokens/MintableERC20.sol';
import {MockAggregator} from '../../src/contracts/mocks/oracle/CLAggregators/MockAggregator.sol';
import {AaveOracle} from '../../src/contracts/misc/AaveOracle.sol';
import {OracleAssertions} from '../src/OracleAssertions.a.sol';
import {IMockPool} from '../src/IMockPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';

contract OracleAssertionsTest is CredibleTest, Test, TestnetProcedures {
  IPoolAddressesProvider public addressesProvider;
  IAaveOracle public oracle;
  IMockPool public pool;
  address public asset;
  MockAggregator public priceFeed;
  IERC20 public underlying;
  IERC20 public variableDebtToken;
  OracleAssertions public assertions;
  string constant ASSERTION_LABEL = 'OracleAssertions';

  function setUp() public {
    // Initialize test environment with real contracts
    initTestEnvironment();

    // Deploy mock token
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Get variable debt token
    (, , address variableDebtUSDX) = contracts.protocolDataProvider.getReserveTokensAddresses(
      asset
    );
    variableDebtToken = IERC20(variableDebtUSDX);

    int256 price = 10e8;

    // Deploy mock price feed with price of 100 USD (8 decimals)
    priceFeed = new MockAggregator(price);

    // Deploy oracle
    address[] memory assets = new address[](1);
    address[] memory sources = new address[](1);
    assets[0] = address(asset);
    sources[0] = address(priceFeed);

    oracle = contracts.aaveOracle;

    vm.prank(poolAdmin);
    oracle.setAssetSources(assets, sources);

    // Set up pool reference
    pool = IMockPool(report.poolProxy);

    // Deploy assertions contract
    assertions = new OracleAssertions(address(oracle), address(pool));

    // Setup initial positions
    vm.startPrank(alice);
    // Supply collateral
    underlying.approve(address(pool), type(uint256).max);
    pool.supply(asset, 1000e6, alice, 0);
    // Borrow some amount
    pool.borrow(asset, 500e6, 2, 0, alice);
    // Ensure alice has enough tokens to repay
    underlying.transfer(alice, 1000e6);
    vm.stopPrank();
  }

  function test_assertionBorrowPriceDeviation() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(OracleAssertions).creationCode,
      abi.encode(address(oracle), address(pool))
    );

    // Set user as the caller
    vm.startPrank(alice);

    // This should pass because price hasn't deviated
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(
        pool.borrow.selector,
        asset,
        100e6,
        DataTypes.InterestRateMode.VARIABLE,
        0,
        alice
      )
    );
    vm.stopPrank();
  }

  function test_assertionSupplyPriceDeviation() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(OracleAssertions).creationCode,
      abi.encode(address(oracle), address(pool))
    );

    // Set user as the caller
    vm.startPrank(alice);

    // This should pass because price hasn't deviated
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, asset, 100e6, alice, 0)
    );
    vm.stopPrank();
  }
}
