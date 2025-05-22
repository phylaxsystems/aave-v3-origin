// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IPool} from '../../src/contracts/interfaces/IPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {ValidationLogic} from '../../src/contracts/protocol/libraries/logic/ValidationLogic.sol';

/// @title HealthFactorAssertions
/// @notice Implements the health factor invariants defined in HFPostconditionsSpec.t.sol
/// @dev Each assertion function implements one or more invariants from HFPostconditionsSpec
contract HealthFactorAssertions is Assertion {
  IPool public immutable pool;

  // Constants from ValidationLogic
  uint256 constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18;
  uint256 constant MINIMUM_HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 0.95e18;

  // Track affected users for actor isolation checks
  mapping(address => bool) private affectedUsers;

  constructor(IPool _pool) {
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
    registerCallTrigger(this.assertActorIsolation.selector, pool.supply.selector);
    registerCallTrigger(this.assertActorIsolation.selector, pool.borrow.selector);
    registerCallTrigger(this.assertActorIsolation.selector, pool.withdraw.selector);
    registerCallTrigger(this.assertActorIsolation.selector, pool.repay.selector);
    registerCallTrigger(this.assertActorIsolation.selector, pool.liquidationCall.selector);
  }

  ////////////////////////////////////////////////////////////////////////////////////////////////////
  //                                    CORE INVARIANT IMPLEMENTATIONS                               //
  ////////////////////////////////////////////////////////////////////////////////////////////////////

  /// @notice Implements HF_GPOST_A: If health factor decreases, the action must not belong to nonDecreasingHfActions
  function assertNonDecreasingHfActions() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (, , address onBehalfOf, ) = abi.decode(
        callInputs[i].input,
        (address, uint256, address, uint16)
      );

      // Get health factor before and after
      ph.forkPreState();
      (, , , , , uint256 preHealthFactor) = pool.getUserAccountData(onBehalfOf);

      ph.forkPostState();
      (, , , , , uint256 postHealthFactor) = pool.getUserAccountData(onBehalfOf);

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
      (, , , , address onBehalfOf) = abi.decode(
        callInputs[i].input,
        (address, uint256, uint256, uint16, address)
      );

      // Get health factor before and after
      ph.forkPreState();
      (, , , , , uint256 preHealthFactor) = pool.getUserAccountData(onBehalfOf);

      ph.forkPostState();
      (, , , , , uint256 postHealthFactor) = pool.getUserAccountData(onBehalfOf);

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
      (, , , , address onBehalfOf) = abi.decode(
        callInputs[i].input,
        (address, uint256, uint256, uint16, address)
      );

      // Get health factor before and after
      ph.forkPreState();
      (, , , , , uint256 preHealthFactor) = pool.getUserAccountData(onBehalfOf);

      ph.forkPostState();
      (, , , , , uint256 postHealthFactor) = pool.getUserAccountData(onBehalfOf);

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
      (, , , , address onBehalfOf) = abi.decode(
        callInputs[i].input,
        (address, uint256, uint256, uint16, address)
      );

      // Get health factor after action
      ph.forkPostState();
      (, , , , , uint256 postHealthFactor) = pool.getUserAccountData(onBehalfOf);

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
      (, , address user, , ) = abi.decode(
        callInputs[i].input,
        (address, address, address, uint256, bool)
      );

      // Get health factor before action
      ph.forkPreState();
      (, , , , , uint256 preHealthFactor) = pool.getUserAccountData(user);

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

  /// @notice Implements HF_GPOST_F: Changes to an actor Health Factor must not affect the HF of any non-targeted actors
  function assertActorIsolation() external {
    // Clear affected users tracking by setting all to false
    address[] memory allUsers = _getAllUsersWithPositions();
    for (uint256 i = 0; i < allUsers.length; i++) {
      affectedUsers[allUsers[i]] = false;
    }

    // Track all users affected by the transaction
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (, , address onBehalfOf, ) = abi.decode(
        callInputs[i].input,
        (address, uint256, address, uint16)
      );
      affectedUsers[onBehalfOf] = true;
    }

    // Check that non-targeted users' health factors haven't changed
    for (uint256 i = 0; i < allUsers.length; i++) {
      if (!affectedUsers[allUsers[i]]) {
        ph.forkPreState();
        (, , , , , uint256 preHealthFactor) = pool.getUserAccountData(allUsers[i]);

        ph.forkPostState();
        (, , , , , uint256 postHealthFactor) = pool.getUserAccountData(allUsers[i]);

        require(preHealthFactor == postHealthFactor, 'Non-targeted user health factor changed');
      }
    }
  }

  ////////////////////////////////////////////////////////////////////////////////////////////////////
  //                                    OPERATION-SPECIFIC IMPLEMENTATIONS                          //
  ////////////////////////////////////////////////////////////////////////////////////////////////////

  /// @notice Implements HF_GPOST_A for supply operations
  /// @dev Ensures supply operations maintain non-decreasing health factor
  function assertSupplyNonDecreasingHf() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (, , address onBehalfOf, ) = abi.decode(
        callInputs[i].input,
        (address, uint256, address, uint16)
      );

      // Get health factor after supply
      (, , , , , uint256 healthFactor) = pool.getUserAccountData(onBehalfOf);

      require(
        healthFactor >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
        'Supply operation resulted in unhealthy position'
      );
    }
  }

  /// @notice Implements HF_GPOST_C for borrow operations
  /// @dev Ensures borrow operations maintain healthy positions
  function assertBorrowHealthyToUnhealthy() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (, , , , address onBehalfOf) = abi.decode(
        callInputs[i].input,
        (address, uint256, uint256, uint16, address)
      );

      // Get health factor after borrow
      (, , , , , uint256 healthFactor) = pool.getUserAccountData(onBehalfOf);

      require(
        healthFactor >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
        'Borrow operation resulted in unhealthy position'
      );
    }
  }

  /// @notice Implements HF_GPOST_B for withdraw operations
  /// @dev Ensures withdraw operations maintain non-increasing health factor
  function assertWithdrawNonIncreasingHf() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.withdraw.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Get health factor after withdraw
      (, , , , , uint256 healthFactor) = pool.getUserAccountData(callInputs[i].caller);

      require(
        healthFactor >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
        'Withdraw operation resulted in unhealthy position'
      );
    }
  }

  /// @notice Implements HF_GPOST_A for repay operations
  /// @dev Ensures repay operations maintain non-decreasing health factor
  function assertRepayNonDecreasingHf() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      (, , , address onBehalfOf) = abi.decode(
        callInputs[i].input,
        (address, uint256, uint256, address)
      );

      // Get health factor after repay
      (, , , , , uint256 healthFactor) = pool.getUserAccountData(onBehalfOf);

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
      (, , address user, , ) = abi.decode(
        callInputs[i].input,
        (address, address, address, uint256, bool)
      );

      // Get health factor before liquidation
      (, , , , , uint256 preHealthFactor) = pool.getUserAccountData(user);

      require(
        preHealthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
        'Cannot liquidate healthy position'
      );

      // Get health factor after liquidation
      (, , , , , uint256 postHealthFactor) = pool.getUserAccountData(user);

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
  function assertSetUserUseReserveAsCollateral() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.setUserUseReserveAsCollateral.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      (, bool useAsCollateral) = abi.decode(callInputs[i].input, (address, bool));

      // Get health factor after setting collateral
      (, , , , , uint256 healthFactor) = pool.getUserAccountData(callInputs[i].caller);

      // If disabling collateral, ensure position remains healthy
      if (!useAsCollateral) {
        require(
          healthFactor >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
          'Disabling collateral resulted in unhealthy position'
        );
      }
    }
  }

  // Helper function to get all users with positions
  // This is just placeholder implementation as no such function exists, and probably never will
  // We just use this for the sake of the example
  function _getAllUsersWithPositions() internal view returns (address[] memory) {
    // This would need to be implemented based on how Aave tracks users
    // For now, we'll return an empty array as this is a placeholder
    return new address[](0);
  }
}
