// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockPool} from './IMockPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from '../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';

contract LiquidationInvariantAssertions is Assertion {
  IMockPool public pool;

  constructor(IMockPool _pool) {
    pool = _pool;
  }

  function triggers() public view override {
    // Register triggers for liquidation functions
    registerCallTrigger(this.assertHealthFactorThreshold.selector, pool.liquidationCall.selector);
    registerCallTrigger(this.assertGracePeriod.selector, pool.liquidationCall.selector);
    registerCallTrigger(this.assertCloseFactorConditions.selector, pool.liquidationCall.selector);
    registerCallTrigger(this.assertLiquidationAmounts.selector, pool.liquidationCall.selector);
    registerCallTrigger(this.assertDeficitCreation.selector, pool.liquidationCall.selector);
    registerCallTrigger(this.assertDeficitAccounting.selector, pool.liquidationCall.selector);
    registerCallTrigger(this.assertDeficitAmount.selector, pool.liquidationCall.selector);
    registerCallTrigger(this.assertActiveReserveDeficit.selector, pool.liquidationCall.selector);
  }

  // LIQUIDATION_HSPOST_A: A liquidation can only be performed once a users health-factor drops below 1
  function assertHealthFactorThreshold() external {
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
      ph.forkPreState();
      (, , , , , uint256 healthFactor) = pool.getUserAccountData(user);

      // Check health factor is below 1
      require(healthFactor < 1e18, 'User health factor not below 1');
    }
  }

  // LIQUIDATION_HSPOST_B: No position on a reserve can be liquidated under grace period
  function assertGracePeriod() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address collateralAsset, , , , ) = abi.decode(
        callInputs[i].input,
        (address, address, address, uint256, bool)
      );

      uint40 gracePeriodUntil = pool.getLiquidationGracePeriod(collateralAsset);
      require(block.timestamp >= gracePeriodUntil, 'Collateral in grace period');
    }
  }

  // LIQUIDATION_HSPOST_F: If more than totalUserDebt * CLOSE_FACTOR can be liquidated in a single liquidation,
  // either totalDebtBase < MIN_BASE_MAX_CLOSE_FACTOR_THRESHOLD or healthFactor < 0.95
  function assertCloseFactorConditions() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      (, , address user, uint256 debtToCover, ) = abi.decode(
        callInputs[i].input,
        (address, address, address, uint256, bool)
      );

      // Get user data before liquidation
      ph.forkPreState();
      (, uint256 totalDebtBase, , , , uint256 healthFactor) = pool.getUserAccountData(user);

      // Get close factor
      uint256 closeFactor = pool.getCloseFactor();

      // If liquidating more than close factor allows
      if (debtToCover > (totalDebtBase * closeFactor) / 1e4) {
        require(
          totalDebtBase < pool.MIN_BASE_MAX_CLOSE_FACTOR_THRESHOLD() || healthFactor < 0.95e18,
          'Close factor conditions not met'
        );
      }
    }
  }

  // LIQUIDATION_HSPOST_H: Liquidation must fully liquidate debt or fully liquidate collateral or leave at least MIN_LEFTOVER_BASE on both
  function assertLiquidationAmounts() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address collateralAsset, address debtAsset, address user, , ) = abi.decode(
        callInputs[i].input,
        (address, address, address, uint256, bool)
      );

      // Get balances after
      ph.forkPostState();
      uint256 postCollateralBalance = pool.getUserCollateralBalance(user, collateralAsset);
      uint256 postDebtBalance = pool.getUserDebtBalance(user, debtAsset);

      // Check if either fully liquidated or minimum leftover maintained
      bool fullyLiquidatedDebt = postDebtBalance == 0;
      bool fullyLiquidatedCollateral = postCollateralBalance == 0;
      bool minimumLeftover = postDebtBalance >= pool.MIN_LEFTOVER_BASE() &&
        postCollateralBalance >= pool.MIN_LEFTOVER_BASE();

      require(
        fullyLiquidatedDebt || fullyLiquidatedCollateral || minimumLeftover,
        'Liquidation amounts do not meet requirements'
      );
    }
  }

  // LIQUIDATION_HSPOST_L: Liquidation only creates deficit if user collateral across reserves == 0 while debt across reserves != 0
  function assertDeficitCreation() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      (, , address user, , ) = abi.decode(
        callInputs[i].input,
        (address, address, address, uint256, bool)
      );

      // Get user data after liquidation
      ph.forkPostState();
      (uint256 totalCollateralBase, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(user);

      // If deficit was created
      if (totalDebtBase > 0) {
        require(totalCollateralBase == 0, 'Deficit created with remaining collateral');
      }
    }
  }

  // LIQUIDATION_HSPOST_M: Whenever a deficit is created as a result of a liquidation, the user's excess debt should be burned and accounted for as deficit
  function assertDeficitAccounting() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      (, address debtAsset, address user, , ) = abi.decode(
        callInputs[i].input,
        (address, address, address, uint256, bool)
      );

      // Get deficit before
      ph.forkPreState();
      uint256 preDeficit = pool.getReserveDeficit(debtAsset);

      // Get deficit after
      ph.forkPostState();
      uint256 postDeficit = pool.getReserveDeficit(debtAsset);

      // If deficit increased
      if (postDeficit > preDeficit) {
        // Get user debt before
        ph.forkPreState();
        uint256 preUserDebt = pool.getUserDebtBalance(user, debtAsset);

        // Get user debt after
        ph.forkPostState();
        uint256 postUserDebt = pool.getUserDebtBalance(user, debtAsset);

        // Check deficit increase matches debt burn
        require(
          postDeficit - preDeficit == preUserDebt - postUserDebt,
          'Deficit accounting mismatch'
        );
      }
    }
  }

  // LIQUIDATION_HSPOST_N: Deficit added during the liquidation cannot be more than the user's debt
  function assertDeficitAmount() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      (, , address user, , ) = abi.decode(
        callInputs[i].input,
        (address, address, address, uint256, bool)
      );

      // Get user debt before
      ph.forkPreState();
      (, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(user);

      // Get deficit before and after
      ph.forkPreState();
      uint256 preDeficit = pool.getReserveDeficit(address(0)); // Assuming deficit is tracked per reserve
      ph.forkPostState();
      uint256 postDeficit = pool.getReserveDeficit(address(0));

      // Check deficit increase doesn't exceed user debt
      require(postDeficit - preDeficit <= totalDebtBase, 'Deficit increase exceeds user debt');
    }
  }

  // LIQUIDATION_HSPOST_O: Deficit can only be created and eliminated for an active reserve
  function assertActiveReserveDeficit() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.liquidationCall.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      (address collateralAsset, address debtAsset, , , ) = abi.decode(
        callInputs[i].input,
        (address, address, address, uint256, bool)
      );

      // Get reserve data
      DataTypes.ReserveDataLegacy memory collateralReserve = pool.getReserveData(collateralAsset);
      DataTypes.ReserveDataLegacy memory debtReserve = pool.getReserveData(debtAsset);

      // Check reserves are active
      require(
        ReserveConfiguration.getActive(collateralReserve.configuration),
        'Collateral reserve not active'
      );
      require(ReserveConfiguration.getActive(debtReserve.configuration), 'Debt reserve not active');
    }
  }
}
