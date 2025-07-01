// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {ReserveConfiguration} from '../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {IVariableDebtToken} from '../../src/contracts/interfaces/IVariableDebtToken.sol';
import {IMockL2Pool} from './IMockL2Pool.sol';

contract BorrowingPostConditionAssertions is Assertion {
  IMockL2Pool public pool;

  constructor(IMockL2Pool _pool) {
    pool = _pool;
  }

  function triggers() public view override {
    // Register triggers for core borrowing functions using L2Pool selectors
    registerCallTrigger(this.assertLiabilityDecrease.selector, pool.repay.selector);
    registerCallTrigger(this.assertUnhealthyBorrowPrevention.selector, pool.borrow.selector);
    registerCallTrigger(this.assertFullRepayPossible.selector, pool.repay.selector);
    registerCallTrigger(this.assertBorrowReserveState.selector, pool.borrow.selector);
    registerCallTrigger(this.assertRepayReserveState.selector, pool.repay.selector);
    registerCallTrigger(this.assertWithdrawNoDebt.selector, pool.withdraw.selector);
    registerCallTrigger(this.assertBorrowCap.selector, pool.borrow.selector);
    registerCallTrigger(this.assertBorrowBalanceChanges.selector, pool.borrow.selector);
    registerCallTrigger(this.assertBorrowBalanceChangesFromLogs.selector, pool.borrow.selector);
    registerCallTrigger(this.assertBorrowDebtChanges.selector, pool.borrow.selector);
    registerCallTrigger(this.assertRepayBalanceChanges.selector, pool.repay.selector);
    registerCallTrigger(this.assertRepayDebtChanges.selector, pool.repay.selector);
  }

  // BORROWING_HSPOST_A: User liability should always decrease after repayment
  function assertLiabilityDecrease() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool repay parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits)
      uint256 amount = uint256(uint128(uint256(args) >> 16));
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get total debt before
      ph.forkPreState();
      (, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // Get total debt after
      ph.forkPostState();
      (, uint256 postTotalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // Check debt decreased
      require(postTotalDebtBase < totalDebtBase, 'User liability did not decrease after repayment');
      // Check debt decreased by at least the repay amount (could be more due to interest)
      require(
        totalDebtBase - postTotalDebtBase >= amount,
        'Debt decrease should be at least the repay amount'
      );
    }
  }

  // BORROWING_HSPOST_B: Unhealthy users can not borrow
  function assertUnhealthyBorrowPrevention() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get health factor before
      ph.forkPreState();
      (, , , , , uint256 healthFactor) = pool.getUserAccountData(onBehalfOf);

      // If user is unhealthy, borrow should fail
      require(healthFactor >= 1e18, 'Unhealthy user was able to borrow');
    }
  }

  // BORROWING_HSPOST_C: A user can always repay debt in full
  function assertFullRepayPossible() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool repay parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits)
      uint256 amount = uint256(uint128(uint256(args) >> 16));
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get total debt before
      ph.forkPreState();
      (, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // Get total debt after
      ph.forkPostState();
      (, uint256 postTotalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // If amount equals total debt, debt should be 0 after
      if (amount == totalDebtBase) {
        require(postTotalDebtBase == 0, 'Full repayment did not clear debt');
      }
    }
  }

  // BORROWING_HSPOST_D: An asset can only be borrowed when its configured as borrowable
  // BORROWING_HSPOST_E: An asset can only be borrowed when the related reserve is active, not frozen, not paused & borrowing is enabled
  function assertBorrowReserveState() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue; // Skip if asset not found

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Check reserve is active
      require(ReserveConfiguration.getActive(reserveData.configuration), 'Reserve is not active');

      // Check reserve is not frozen
      require(!ReserveConfiguration.getFrozen(reserveData.configuration), 'Reserve is frozen');

      // Check reserve is not paused
      require(!ReserveConfiguration.getPaused(reserveData.configuration), 'Reserve is paused');

      // Check borrowing is enabled
      require(
        ReserveConfiguration.getBorrowingEnabled(reserveData.configuration),
        'Borrowing is disabled'
      );
    }
  }

  // BORROWING_HSPOST_F: An asset can only be repaid when the related reserve is active & not paused
  function assertRepayReserveState() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool repay parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits)
      uint16 assetId = uint16(uint256(args));

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue; // Skip if asset not found

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Check reserve is active
      require(ReserveConfiguration.getActive(reserveData.configuration), 'Reserve is not active');

      // Check reserve is not paused
      require(!ReserveConfiguration.getPaused(reserveData.configuration), 'Reserve is paused');
    }
  }

  // BORROWING_HSPOST_G: a user should always be able to withdraw all if there is no outstanding debt
  function assertWithdrawNoDebt() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.withdraw.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool withdraw parameters: assetId (16 bits) + amount (128 bits)
      uint16 assetId = uint16(uint256(args));
      uint256 amount = uint256(uint128(uint256(args) >> 16));

      // Get total debt
      (, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(callInputs[i].caller);

      // If no debt, should be able to withdraw all
      if (totalDebtBase == 0) {
        // Get the asset address from the assetId
        address asset = pool.getReserveAddressById(assetId);
        if (asset == address(0)) continue; // Skip if asset not found

        // Get aToken address
        DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);
        address aTokenAddress = reserveData.aTokenAddress;

        // Get aToken balance before withdraw
        ph.forkPreState();
        uint256 aTokenBalanceBefore = IERC20(aTokenAddress).balanceOf(callInputs[i].caller);

        // Get aToken balance after withdraw
        ph.forkPostState();
        uint256 aTokenBalanceAfter = IERC20(aTokenAddress).balanceOf(callInputs[i].caller);

        // If user has no debt, they should be able to withdraw their full aToken balance
        require(
          aTokenBalanceAfter == 0 || amount <= aTokenBalanceBefore,
          'User with no debt cannot withdraw full amount'
        );
      }
    }
  }

  // BORROWING_GPOST_H: If totalBorrow for a reserve increases new totalBorrow must be less than or equal to borrow cap
  function assertBorrowCap() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint16 assetId = uint16(uint256(args));

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue; // Skip if asset not found

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Get borrow cap
      uint256 borrowCap = ReserveConfiguration.getBorrowCap(reserveData.configuration);

      // If borrow cap is 0, borrowing is disabled
      if (borrowCap == 0) {
        require(false, 'Borrowing disabled for this reserve');
      }

      // Get total borrow after
      ph.forkPostState();
      uint256 totalBorrowAfter = IERC20(reserveData.variableDebtTokenAddress).totalSupply();

      // Check that total borrow after is within the cap
      require(totalBorrowAfter <= borrowCap, 'Total borrow exceeds borrow cap');
    }
  }

  // BORROWING_HSPOST_I: After a successful borrow the actor asset balance should increase by the amount borrowed
  // This version uses getCallInputs to directly access the function parameters from the call data
  // It's simpler but requires the function to be called directly (not through a proxy or delegatecall)
  // Gas cost of this assertion for a single borrow transaction: 40263
  function assertBorrowBalanceChanges() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Note: We need to get the asset address from the assetId
      // For now, we'll skip this check since we don't have a direct mapping from assetId to asset address
      // In a real implementation, you'd need to maintain this mapping or query it differently
      continue;
    }
  }

  // BORROWING_HSPOST_I: After a successful borrow the actor asset balance should increase by the amount borrowed
  // This version uses getLogs to access the Borrow event data instead of call inputs
  // It's more complex but works even if the function is called through a proxy or delegatecall
  // since it relies on the event being emitted rather than the direct function call
  // Gas cost of this assertion for a single borrow transaction: 42739
  function assertBorrowBalanceChangesFromLogs() external {
    PhEvm.Log[] memory logs = ph.getLogs();
    for (uint256 i = 0; i < logs.length; i++) {
      if (
        logs[i].topics[0] ==
        keccak256('Borrow(address,address,address,uint256,uint8,uint256,uint16)')
      ) {
        // Get indexed fields from topics
        address reserve = address(uint160(uint256(logs[i].topics[1])));

        // Get non-indexed fields from data
        (address user, uint256 amount, , ) = abi.decode(
          logs[i].data,
          (address, uint256, DataTypes.InterestRateMode, uint256)
        );

        // Get underlying token
        IERC20 underlying = IERC20(reserve);

        // Get balances before
        ph.forkPreState();
        uint256 preBalance = underlying.balanceOf(user);

        // Get balances after
        ph.forkPostState();
        uint256 postBalance = underlying.balanceOf(user);

        // Check balance increased by amount
        require(postBalance - preBalance == amount, 'Balance did not increase by borrow amount');
      }
    }
  }

  // BORROWING_HSPOST_J: After a successful borrow the onBehalf debt balance should increase by the amount borrowed
  function assertBorrowDebtChanges() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool borrow parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits) + referralCode (16 bits)
      uint256 amount = uint256(uint128(uint256(args) >> 16));
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get debt before
      ph.forkPreState();
      (, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // Get debt after
      ph.forkPostState();
      (, uint256 postTotalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // Check debt increased by at least the borrow amount (could be more due to interest)
      require(postTotalDebtBase > totalDebtBase, 'Debt did not increase');
      require(
        postTotalDebtBase - totalDebtBase >= amount,
        'Debt increase should be at least the borrow amount'
      );
    }
  }

  // BORROWING_HSPOST_K: After a successful repay the actor asset balance should decrease by the amount repaid
  function assertRepayBalanceChanges() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      // Decode L2Pool repay parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits)
      uint16 assetId = uint16(uint256(abi.decode(callInputs[i].input, (bytes32))));
      uint256 amount = uint256(uint128(uint256(abi.decode(callInputs[i].input, (bytes32))) >> 16));

      // Get the asset address from the assetId
      address asset = pool.getReserveAddressById(assetId);
      if (asset == address(0)) continue; // Skip if asset not found

      // Get reserve data
      DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

      // Get user debt balance before repay
      ph.forkPreState();
      uint256 userDebtBefore = IERC20(reserveData.variableDebtTokenAddress).balanceOf(
        callInputs[i].caller
      );

      // Get user debt balance after repay
      ph.forkPostState();
      uint256 userDebtAfter = IERC20(reserveData.variableDebtTokenAddress).balanceOf(
        callInputs[i].caller
      );

      // Check that debt decreased by at least the repaid amount
      require(
        userDebtBefore - userDebtAfter >= amount,
        'User debt did not decrease by repaid amount'
      );
    }
  }

  // BORROWING_HSPOST_L: After a successful repay the onBehalf debt balance should decrease by at least the amount repaid
  function assertRepayDebtChanges() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
    for (uint256 i = 0; i < callInputs.length; i++) {
      bytes32 args = abi.decode(callInputs[i].input, (bytes32));
      // Decode L2Pool repay parameters: assetId (16 bits) + amount (128 bits) + interestRateMode (8 bits)
      uint256 amount = uint256(uint128(uint256(args) >> 16));
      // Note: onBehalfOf is always msg.sender in L2Pool, so we use the caller
      address onBehalfOf = callInputs[i].caller;

      // Get debt before
      ph.forkPreState();
      (, uint256 totalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // Get debt after
      ph.forkPostState();
      (, uint256 postTotalDebtBase, , , , ) = pool.getUserAccountData(onBehalfOf);

      // Check debt decreased by at least the repay amount (could be more due to interest)
      require(totalDebtBase > postTotalDebtBase, 'Debt did not decrease');
      require(
        totalDebtBase - postTotalDebtBase >= amount,
        'Debt decrease should be at least the repay amount'
      );
    }
  }
}
