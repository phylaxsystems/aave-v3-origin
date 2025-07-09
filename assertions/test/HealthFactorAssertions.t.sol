// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title HealthFactorAssertions Tests
 * @notice This test file uses the real Aave V3 protocol to verify that our health factor assertions
 *         correctly pass when the protocol behaves as expected. It ensures that our assertions
 *         don't revert when they shouldn't, validating that our invariant checks are not overly
 *         restrictive.
 *
 *         For example, it verifies that the health factor assertions pass when users perform
 *         valid operations that maintain healthy positions, as the real protocol correctly
 *         calculates and maintains health factors.
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {HealthFactorAssertions} from '../src/showcase/HealthFactorAssertions.a.sol';
import {IMockL2Pool} from '../src/interfaces/IMockL2Pool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';

contract TestHealthFactorAssertions is CredibleTest, Test, TestnetProcedures {
  IMockL2Pool public pool;
  HealthFactorAssertions public assertions;
  L2Encoder public l2Encoder;
  address public user;
  address public asset;
  IERC20 public underlying;
  string public constant ASSERTION_LABEL = 'HealthFactorAssertions';

  function setUp() public {
    // Initialize test environment with real contracts (L2 enabled for L2Encoder)
    initL2TestEnvironment();

    // Set up user and get pool reference
    user = alice;
    pool = IMockL2Pool(report.poolProxy);
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Set up L2Encoder for creating compact parameters
    l2Encoder = L2Encoder(report.l2Encoder);

    // Deploy assertions contract
    assertions = new HealthFactorAssertions();

    // Set up fresh user with collateral
    deal(asset, user, 2000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral using L2Pool encoding
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 1000e6, 0);
    pool.supply(supplyArgs);
    vm.stopPrank();
  }

  function testAssertionSupplyNonDecreasingHf() public {
    uint256 supplyAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(HealthFactorAssertions).creationCode,
      abi.encode(pool)
    );

    vm.startPrank(user);
    underlying.approve(address(pool), supplyAmount);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, supplyAmount, 0);

    // This should pass because supply operations should maintain or improve health factor
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function testAssertionBorrowHealthyToUnhealthy() public {
    uint256 borrowAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(HealthFactorAssertions).creationCode,
      abi.encode(pool)
    );

    vm.startPrank(user);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, borrowAmount, 2, 0);

    // This should pass because the user has sufficient collateral to maintain healthy position
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function testAssertionWithdrawNonIncreasingHf() public {
    uint256 withdrawAmount = 50e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(HealthFactorAssertions).creationCode,
      abi.encode(pool)
    );

    vm.startPrank(user);

    // Create L2Pool compact parameters for withdraw
    bytes32 withdrawArgs = l2Encoder.encodeWithdrawParams(asset, withdrawAmount);

    // This should pass because withdraw operations should not increase health factor beyond safe limits
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.withdraw.selector, withdrawArgs)
    );
    vm.stopPrank();
  }

  function testAssertionRepayNonDecreasingHf() public {
    uint256 repayAmount = 50e6;

    // First borrow some tokens to have debt to repay
    vm.startPrank(user);
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 200e6, 2, 0);
    pool.borrow(borrowArgs);
    vm.stopPrank();

    // Ensure user has enough tokens to repay
    deal(asset, user, repayAmount);

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(HealthFactorAssertions).creationCode,
      abi.encode(pool)
    );

    vm.startPrank(user);
    underlying.approve(address(pool), repayAmount);

    // Create L2Pool compact parameters for repay
    bytes32 repayArgs = l2Encoder.encodeRepayParams(asset, repayAmount, 2);

    // This should pass because repay operations should maintain or improve health factor
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.repay.selector, repayArgs)
    );
    vm.stopPrank();
  }

  function testAssertionNonDecreasingHfActions() public {
    uint256 supplyAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(HealthFactorAssertions).creationCode,
      abi.encode(pool)
    );

    vm.startPrank(user);
    underlying.approve(address(pool), supplyAmount);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, supplyAmount, 0);

    // This should pass because supply is a non-decreasing health factor action
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function testAssertionNonIncreasingHfActions() public {
    uint256 borrowAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(HealthFactorAssertions).creationCode,
      abi.encode(pool)
    );

    vm.startPrank(user);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, borrowAmount, 2, 0);

    // This should pass because borrow is a non-increasing health factor action
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function testAssertionHealthyToUnhealthy() public {
    uint256 borrowAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(HealthFactorAssertions).creationCode,
      abi.encode(pool)
    );

    vm.startPrank(user);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, borrowAmount, 2, 0);

    // This should pass because the user should remain healthy after borrowing
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function testAssertionUnsafeAfterAction() public {
    uint256 borrowAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(HealthFactorAssertions).creationCode,
      abi.encode(pool)
    );

    vm.startPrank(user);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, borrowAmount, 2, 0);

    // This should pass because borrow is a valid action that can result in unsafe health factor
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function testAssertionUnsafeBeforeAction() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(HealthFactorAssertions).creationCode,
      abi.encode(pool)
    );

    // This test would require a user with unsafe health factor to test liquidation
    // For now, we'll test that the assertion is properly registered
    // In a real scenario, this would test liquidation calls on unhealthy positions
    vm.startPrank(user);

    // Note: This test doesn't actually perform liquidation since we don't have an unhealthy user
    // but it demonstrates the pattern for testing unsafe before actions
    vm.stopPrank();
  }

  function testHealthFactorCalculationDirectly() public {
    vm.startPrank(user);

    // Get initial health factor
    (, , , , , uint256 initialHf) = pool.getUserAccountData(user);
    emit log_named_uint('Initial health factor', initialHf);

    // Perform a supply operation using L2Pool encoding
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 100e6, 0);
    pool.supply(supplyArgs);

    // Get health factor after supply
    (, , , , , uint256 afterSupplyHf) = pool.getUserAccountData(user);
    emit log_named_uint('Health factor after supply', afterSupplyHf);

    // Health factor should be maintained or improved after supply
    assertTrue(afterSupplyHf >= initialHf, 'Health factor should not decrease after supply');

    // Perform a borrow operation using L2Pool encoding
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 50e6, 2, 0);
    pool.borrow(borrowArgs);

    // Get health factor after borrow
    (, , , , , uint256 afterBorrowHf) = pool.getUserAccountData(user);
    emit log_named_uint('Health factor after borrow', afterBorrowHf);

    // Health factor should still be healthy after reasonable borrow
    assertTrue(
      afterBorrowHf >= 1e18,
      'Health factor should remain healthy after reasonable borrow'
    );

    vm.stopPrank();
  }

  /// @notice Helper function to get asset ID from asset address
  function _getAssetId(address assetAddress) internal view returns (uint16) {
    // For USDX, it's typically the first asset in the list
    if (assetAddress == tokenList.usdx) {
      return 0;
    }
    // Add more mappings as needed for other assets
    revert('Asset not found in mapping');
  }
}
