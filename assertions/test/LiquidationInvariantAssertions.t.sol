// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title LiquidationInvariantAssertions Tests
 * @notice This test file uses a mocked protocol (WorkingProtocol) to verify that our assertions
 *         correctly pass when the protocol behaves as expected. We use a mock instead of the
 *         real Aave V3 protocol for simplicity, as setting up the full protocol suite and
 *         manipulating oracle prices would be time-consuming and more appropriate for thorough
 *         integration testing.
 *
 *         The mock protocol implements the core liquidation functionality needed to test our
 *         assertions, allowing us to focus on verifying that our invariant checks correctly
 *         validate expected protocol behavior.
 *
 *         For example, it verifies that the health factor threshold assertion passes when
 *         a user's position is unhealthy and can be liquidated, as the protocol correctly
 *         enforces the health factor requirements.
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {LiquidationInvariantAssertions} from '../src/LiquidationInvariantAssertions.a.sol';
import {IMockPool} from '../src/IMockPool.sol';
import {WorkingProtocol} from '../mocks/WorkingProtocol.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';
import {IPriceOracleGetter} from '../../src/contracts/interfaces/IPriceOracleGetter.sol';
import {IAaveOracle} from '../../src/contracts/interfaces/IAaveOracle.sol';
import {LiquidationDataProvider} from '../../src/contracts/helpers/LiquidationDataProvider.sol';

contract TestLiquidationInvariantAssertions is CredibleTest, Test, TestnetProcedures {
  IMockPool public pool;
  LiquidationInvariantAssertions public assertions;
  address public testUser;
  address public testLiquidator;
  address public testCollateralAsset;
  address public testDebtAsset;
  IERC20 public collateralUnderlying;
  IERC20 public debtUnderlying;
  string constant ASSERTION_LABEL = 'LiquidationInvariantAssertions';
  IAaveOracle public aaveOracle;
  LiquidationDataProvider public liquidationDataProvider;

  function setUp() public {
    // Deploy mock protocol
    pool = new WorkingProtocol();

    // Set up users
    testUser = makeAddr('user');
    testLiquidator = makeAddr('liquidator');
    testCollateralAsset = makeAddr('collateral');
    testDebtAsset = makeAddr('debt');

    // Configure reserves as active
    WorkingProtocol(address(pool)).setReserveActive(testCollateralAsset, true);
    WorkingProtocol(address(pool)).setReserveActive(testDebtAsset, true);

    // Deploy assertions contract
    assertions = new LiquidationInvariantAssertions(pool);

    // Setup initial positions
    vm.startPrank(testUser);
    WorkingProtocol(address(pool)).supply(testCollateralAsset, 1000e6, testUser, 0);
    WorkingProtocol(address(pool)).borrow(testDebtAsset, 500e8, 2, 0, testUser);
    vm.stopPrank();
  }

  function test_assertionHealthFactorThreshold() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LiquidationInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Make position unhealthy - this is the expected state for liquidation
    WorkingProtocol(address(pool)).setHealthFactor(testUser, 0.5e18);

    // Set liquidator as the caller
    vm.startPrank(testLiquidator);

    // This should pass because the user's position is unhealthy and can be liquidated
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(
        pool.liquidationCall.selector,
        testCollateralAsset,
        testDebtAsset,
        testUser,
        100e8,
        false
      )
    );
    vm.stopPrank();
  }

  function test_assertionGracePeriod() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LiquidationInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set grace period to be in the past - this is the expected state for liquidation
    WorkingProtocol(address(pool)).setLiquidationGracePeriod(
      testCollateralAsset,
      uint40(block.timestamp)
    );

    // Fast forward time to be past the grace period
    vm.warp(block.timestamp + 1 days);

    // Make position unhealthy
    WorkingProtocol(address(pool)).setHealthFactor(testUser, 0.5e18);

    // Set liquidator as the caller
    vm.startPrank(testLiquidator);

    // This should pass because the grace period has expired and liquidation is allowed
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(
        pool.liquidationCall.selector,
        testCollateralAsset,
        testDebtAsset,
        testUser,
        100e8,
        false
      )
    );
    vm.stopPrank();
  }
}

contract MockAggregator {
  int256 private _price;

  constructor(int256 price) {
    _price = price;
  }

  function latestAnswer() external view returns (int256) {
    return _price;
  }
}
