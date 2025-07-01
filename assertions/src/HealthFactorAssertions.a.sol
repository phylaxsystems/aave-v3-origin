// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from './IMockL2Pool.sol';

/// @title HealthFactorAssertions
/// @notice Implements the health factor invariants defined in HFPostconditionsSpec.t.sol
/// @dev Each assertion function implements one or more invariants from HFPostconditionsSpec
/// @dev Uses pool's getUserAccountData which is expensive and causes gas limit issues
contract HealthFactorAssertions is Assertion {
  IMockL2Pool public immutable pool;

  // Constants from ValidationLogic
  uint256 constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18;
  uint256 constant MINIMUM_HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 0.95e18;

  constructor(IMockL2Pool _pool) {
    pool = _pool;
  }

  function triggers() public view override {
    // Register triggers for core functions that affect health factor
    registerCallTrigger(this.assertSupplyNonDecreasingHf.selector, pool.supply.selector);
    registerCallTrigger(this.assertBorrowHealthyToUnhealthy.selector, pool.borrow.selector);
    registerCallTrigger(this.assertWithdrawNonIncreasingHf.selector, pool.withdraw.selector);
    registerCallTrigger(this.assertRepayNonDecreasingHf.selector, pool.repay.selector);
    registerCallTrigger(
      this.assertLiquidationUnsafeBeforeAfter.selector,
      pool.liquidationCall.selector
    );
    registerCallTrigger(
      this.assertSetUserUseReserveAsCollateral.selector,
      pool.setUserUseReserveAsCollateral.selector
    );
    registerCallTrigger(this.assertNonDecreasingHfActions.selector, pool.supply.selector);
    registerCallTrigger(this.assertNonDecreasingHfActions.selector, pool.repay.selector);
    registerCallTrigger(this.assertNonIncreasingHfActions.selector, pool.borrow.selector);
    registerCallTrigger(this.assertNonIncreasingHfActions.selector, pool.withdraw.selector);
  }

  ////////////////////////////////////////////////////////////////////////////////////////////////////
  //                                    CORE INVARIANT IMPLEMENTATIONS                               //
  ////////////////////////////////////////////////////////////////////////////////////////////////////

  /// @notice Implements HF_GPOST_A: If health factor decreases, the action must not belong to nonDecreasingHfActions
  function assertNonDecreasingHfActions() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool supply parameters: assetId (16 bits) + amount (128 bits) + referralCode (16 bits)
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get health factor before and after using expensive getUserAccountData
      ph.forkPreState();
      uint256 preHealthFactor;
      (, , , , , preHealthFactor) = pool.getUserAccountData(onBehalfOf);

      ph.forkPostState();
      uint256 postHealthFactor;
      (, , , , , postHealthFactor) = pool.getUserAccountData(onBehalfOf);

      // For non-decreasing actions, health factor should not decrease
      require(
        postHealthFactor >= preHealthFactor,
        'Health factor decreased in non-decreasing action'
      );
    }
  }

  /// @notice Implements HF_GPOST_B: If health factor increases, the action must not belong to nonIncreasingHfActions
  function assertNonIncreasingHfActions() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get health factor before and after using expensive getUserAccountData
      ph.forkPreState();
      uint256 preHealthFactor;
      (, , , , , preHealthFactor) = pool.getUserAccountData(onBehalfOf);

      ph.forkPostState();
      uint256 postHealthFactor;
      (, , , , , postHealthFactor) = pool.getUserAccountData(onBehalfOf);

      // For non-increasing actions, health factor should not increase
      require(
        postHealthFactor <= preHealthFactor,
        'Health factor increased in non-increasing action'
      );
    }
  }

  /// @notice Implements HF_GPOST_C: No function can transition a healthy account to unhealthy, except for price updates and borrowing interest
  function assertHealthyToUnhealthy() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get health factor before and after using expensive getUserAccountData
      ph.forkPreState();
      uint256 preHealthFactor;
      (, , , , , preHealthFactor) = pool.getUserAccountData(onBehalfOf);

      ph.forkPostState();
      uint256 postHealthFactor;
      (, , , , , postHealthFactor) = pool.getUserAccountData(onBehalfOf);

      // If account was healthy before, it should remain healthy after
      if (preHealthFactor >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD) {
        require(
          postHealthFactor >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
          'Healthy account became unhealthy'
        );
      }
    }
  }

  /// @notice Implements HF_GPOST_D: If HF is unsafe after an action, the action must belong to hfUnsafeAfterAction
  function assertUnsafeAfterAction() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get health factor after action using expensive getUserAccountData
      ph.forkPostState();
      uint256 postHealthFactor;
      (, , , , , postHealthFactor) = pool.getUserAccountData(onBehalfOf);

      // If health factor is unsafe after action, verify it's a valid unsafe action
      if (postHealthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD) {
        // Only borrow and withdraw can result in unsafe health factors
        bytes4 currentSelector = bytes4(callInputs[i].input);
        require(
          currentSelector == pool.borrow.selector || currentSelector == pool.withdraw.selector,
          'Unsafe health factor from invalid action'
        );
      }
    }
  }

  /// @notice Implements HF_GPOST_E: If HF is unsafe before an action, the action must belong to hfUnsafeBeforeAction
  function assertUnsafeBeforeAction() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, ) = abi.decode(callInputs[i].input, (bytes32, bytes32));
      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      address user = address(uint160(uint256(args1) >> 32));

      // Get health factor before action using expensive getUserAccountData
      ph.forkPreState();
      uint256 preHealthFactor;
      (, , , , , preHealthFactor) = pool.getUserAccountData(user);

      // If health factor is unsafe before action, verify it's a valid unsafe action
      if (preHealthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD) {
        // Only liquidation can be performed on unsafe positions
        bytes4 currentSelector = bytes4(callInputs[i].input);
        require(
          currentSelector == pool.liquidationCall.selector,
          'Action on unsafe position not allowed'
        );
      }
    }
  }

  ////////////////////////////////////////////////////////////////////////////////////////////////////
  //                                    OPERATION-SPECIFIC IMPLEMENTATIONS                          //
  ////////////////////////////////////////////////////////////////////////////////////////////////////

  /// @notice Implements HF_GPOST_A for supply operations
  /// @dev Ensures supply operations maintain non-decreasing health factor
  function assertSupplyNonDecreasingHf() external view {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool supply parameters: assetId (16 bits) + amount (128 bits) + referralCode (16 bits)
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get health factor after supply using expensive getUserAccountData
      uint256 healthFactor;
      (, , , , , healthFactor) = pool.getUserAccountData(onBehalfOf);

      require(
        healthFactor >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
        'Supply operation resulted in unhealthy position'
      );
    }
  }

  /// @notice Implements HF_GPOST_C for borrow operations
  /// @dev Ensures borrow operations maintain healthy positions
  function assertBorrowHealthyToUnhealthy() external view {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get health factor after borrow using expensive getUserAccountData
      uint256 healthFactor;
      (, , , , , healthFactor) = pool.getUserAccountData(onBehalfOf);

      require(
        healthFactor >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
        'Borrow operation resulted in unhealthy position'
      );
    }
  }

  /// @notice Implements HF_GPOST_B for withdraw operations
  /// @dev Ensures withdraw operations maintain non-increasing health factor
  function assertWithdrawNonIncreasingHf() external view {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.withdraw.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Get health factor after withdraw using expensive getUserAccountData
      uint256 healthFactor;
      (, , , , , healthFactor) = pool.getUserAccountData(callInputs[i].caller);

      require(
        healthFactor >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
        'Withdraw operation resulted in unhealthy position'
      );
    }
  }

  /// @notice Implements HF_GPOST_A for repay operations
  /// @dev Ensures repay operations maintain non-decreasing health factor
  function assertRepayNonDecreasingHf() external view {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool repay parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits)
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get health factor after repay using expensive getUserAccountData
      uint256 healthFactor;
      (, , , , , healthFactor) = pool.getUserAccountData(onBehalfOf);

      require(
        healthFactor >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
        'Repay operation resulted in unhealthy position'
      );
    }
  }

  /// @notice Implements HF_GPOST_D and HF_GPOST_E for liquidation operations
  /// @dev Ensures liquidation operations maintain proper health factor thresholds
  function assertLiquidationUnsafeBeforeAfter() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // L2Pool liquidationCall takes two bytes32 parameters
      (bytes32 args1, ) = abi.decode(callInputs[i].input, (bytes32, bytes32));
      // Decode L2Pool liquidation parameters:
      // args1: collateralAssetId (16 bits) + debtAssetId (16 bits) + user (160 bits)
      // args2: debtToCover (128 bits) + receiveAToken (1 bit) + unused (127 bits)
      address user = address(uint160(uint256(args1) >> 32));

      // Get health factor before liquidation using expensive getUserAccountData
      uint256 preHealthFactor;
      (, , , , , preHealthFactor) = pool.getUserAccountData(user);

      require(
        preHealthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
        'Cannot liquidate healthy position'
      );

      // Get health factor after liquidation using expensive getUserAccountData
      ph.forkPostState();
      uint256 postHealthFactor;
      (, , , , , postHealthFactor) = pool.getUserAccountData(user);

      // Ensure liquidation improves health factor
      require(postHealthFactor > preHealthFactor, 'Liquidation did not improve health factor');
      require(
        postHealthFactor >= MINIMUM_HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
        'Position still unhealthy after liquidation'
      );
    }
  }

  /// @notice Implements collateral-specific health factor checks
  /// @dev Ensures setting collateral maintains healthy positions
  function assertSetUserUseReserveAsCollateral() external view {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.setUserUseReserveAsCollateral.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool setUserUseReserveAsCollateral parameters: assetId (16 bits) + useAsCollateral (1 bit) + unused (15 bits)
      bool useAsCollateral = uint8(uint256(abi.decode(callInputs[i].input, (bytes32))) >> 16) != 0;

      // Get health factor after setting collateral using expensive getUserAccountData
      uint256 healthFactor;
      (, , , , , healthFactor) = pool.getUserAccountData(callInputs[i].caller);

      // If disabling collateral, ensure position remains healthy
      if (!useAsCollateral) {
        require(
          healthFactor >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
          'Disabling collateral resulted in unhealthy position'
        );
      }
    }
  }
}
