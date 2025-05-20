// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {DataTypes} from "../../src/contracts/protocol/libraries/types/DataTypes.sol";
import {IERC20} from "../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {ReserveConfiguration} from "../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {UserConfiguration} from "../../src/contracts/protocol/libraries/configuration/UserConfiguration.sol";
import {IVariableDebtToken} from "../../src/contracts/interfaces/IVariableDebtToken.sol";
import {IMockPool} from "./IMockPool.sol";

contract BorrowingPostConditionAssertions is Assertion {
    IMockPool public immutable pool;

    constructor(IMockPool _pool) {
        pool = _pool;
    }

    function triggers() public view override {
        // Register triggers for core borrowing functions
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
            (, uint256 amount,, address onBehalfOf) =
                abi.decode(callInputs[i].input, (address, uint256, uint256, address));

            // Get total debt before
            ph.forkPreState();
            (, uint256 totalDebtBase,,,,) = pool.getUserAccountData(onBehalfOf);

            // Get total debt after
            ph.forkPostState();
            (, uint256 postTotalDebtBase,,,,) = pool.getUserAccountData(onBehalfOf);

            // Check debt decreased
            require(postTotalDebtBase < totalDebtBase, "User liability did not decrease after repayment");
            // Check debt decreased by at least the repay amount (could be more due to interest)
            require(totalDebtBase - postTotalDebtBase >= amount, "Debt decrease should be at least the repay amount");
        }
    }

    // BORROWING_HSPOST_B: Unhealthy users can not borrow
    function assertUnhealthyBorrowPrevention() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (,,,, address onBehalfOf) = abi.decode(callInputs[i].input, (address, uint256, uint256, uint16, address));

            // Get health factor before
            ph.forkPreState();
            (,,,,, uint256 healthFactor) = pool.getUserAccountData(onBehalfOf);

            // If user is unhealthy, borrow should fail
            require(healthFactor >= 1e18, "Unhealthy user was able to borrow");
        }
    }

    // BORROWING_HSPOST_C: A user can always repay debt in full
    function assertFullRepayPossible() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (, uint256 amount,, address onBehalfOf) =
                abi.decode(callInputs[i].input, (address, uint256, uint256, address));

            // Get total debt before
            ph.forkPreState();
            (, uint256 totalDebtBase,,,,) = pool.getUserAccountData(onBehalfOf);

            // Get total debt after
            ph.forkPostState();
            (, uint256 postTotalDebtBase,,,,) = pool.getUserAccountData(onBehalfOf);

            // If amount equals total debt, debt should be 0 after
            if (amount == totalDebtBase) {
                require(postTotalDebtBase == 0, "Full repayment did not clear debt");
            }
        }
    }

    // BORROWING_HSPOST_D: An asset can only be borrowed when its configured as borrowable
    // BORROWING_HSPOST_E: An asset can only be borrowed when the related reserve is active, not frozen, not paused & borrowing is enabled
    function assertBorrowReserveState() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (address asset,,,,) = abi.decode(callInputs[i].input, (address, uint256, uint256, uint16, address));

            // Get reserve data
            DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

            // Check reserve state
            require(ReserveConfiguration.getActive(reserveData.configuration), "Reserve is not active");
            require(!ReserveConfiguration.getFrozen(reserveData.configuration), "Reserve is frozen");
            require(!ReserveConfiguration.getPaused(reserveData.configuration), "Reserve is paused");
            require(ReserveConfiguration.getBorrowingEnabled(reserveData.configuration), "Borrowing is not enabled");
        }
    }

    // BORROWING_HSPOST_F: An asset can only be repaid when the related reserve is active & not paused
    function assertRepayReserveState() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (address asset,,,) = abi.decode(callInputs[i].input, (address, uint256, uint256, address));

            // Get reserve data
            DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

            // Check reserve state
            require(ReserveConfiguration.getActive(reserveData.configuration), "Reserve is not active");
            require(!ReserveConfiguration.getPaused(reserveData.configuration), "Reserve is paused");
        }
    }

    // BORROWING_HSPOST_G: a user should always be able to withdraw all if there is no outstanding debt
    function assertWithdrawNoDebt() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.withdraw.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (address asset, uint256 amount,) = abi.decode(callInputs[i].input, (address, uint256, address));

            // Get total debt
            (, uint256 totalDebtBase,,,,) = pool.getUserAccountData(callInputs[i].caller);

            // If no debt, should be able to withdraw all
            if (totalDebtBase == 0) {
                // Get aToken balance
                DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);
                IERC20 aToken = IERC20(reserveData.aTokenAddress);
                uint256 aTokenBalance = aToken.balanceOf(callInputs[i].caller);

                // Should be able to withdraw all
                require(amount <= aTokenBalance, "Cannot withdraw all when no debt");
            }
        }
    }

    // BORROWING_GPOST_H: If totalBorrow for a reserve increases new totalBorrow must be less than or equal to borrow cap
    function assertBorrowCap() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (address asset,,,,) = abi.decode(callInputs[i].input, (address, uint256, uint256, uint16, address));

            // Get reserve data
            DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);

            // Get total borrow before
            ph.forkPreState();
            IVariableDebtToken variableDebtToken = IVariableDebtToken(reserveData.variableDebtTokenAddress);
            uint256 preTotalBorrow = variableDebtToken.scaledTotalSupply();

            // Get total borrow after
            ph.forkPostState();
            uint256 postTotalBorrow = variableDebtToken.scaledTotalSupply();

            // Check borrow increased (since this is a borrow operation)
            require(postTotalBorrow > preTotalBorrow, "Total borrow did not increase");
            uint256 borrowCap = ReserveConfiguration.getBorrowCap(reserveData.configuration);
            if (borrowCap != 0) {
                // 0 means no cap
                require(postTotalBorrow <= borrowCap, "Total borrow exceeds borrow cap");
            }
        }
    }

    // BORROWING_HSPOST_I: After a successful borrow the actor asset balance should increase by the amount borrowed
    // This version uses getCallInputs to directly access the function parameters from the call data
    // It's simpler but requires the function to be called directly (not through a proxy or delegatecall)
    // Gas cost of this assertion for a single borrow transaction: 40263
    function assertBorrowBalanceChanges() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (address asset, uint256 amount,,,) =
                abi.decode(callInputs[i].input, (address, uint256, uint256, uint16, address));

            // Get underlying token
            IERC20 underlying = IERC20(asset);

            // Get balances before
            ph.forkPreState();
            uint256 preBalance = underlying.balanceOf(callInputs[i].caller);

            // Get balances after
            ph.forkPostState();
            uint256 postBalance = underlying.balanceOf(callInputs[i].caller);

            // Check balance increased by amount
            require(postBalance - preBalance == amount, "Balance did not increase by borrow amount");
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
            if (logs[i].topics[0] == keccak256("Borrow(address,address,address,uint256,uint8,uint256,uint16)")) {
                // Get indexed fields from topics
                address reserve = address(uint160(uint256(logs[i].topics[1])));
                address onBehalfOf = address(uint160(uint256(logs[i].topics[2])));
                uint16 referralCode = uint16(uint256(logs[i].topics[3]));

                // Get non-indexed fields from data
                (address user, uint256 amount, DataTypes.InterestRateMode interestRateMode, uint256 borrowRate) =
                    abi.decode(logs[i].data, (address, uint256, DataTypes.InterestRateMode, uint256));

                // Get underlying token
                IERC20 underlying = IERC20(reserve);

                // Get balances before
                ph.forkPreState();
                uint256 preBalance = underlying.balanceOf(user);

                // Get balances after
                ph.forkPostState();
                uint256 postBalance = underlying.balanceOf(user);

                // Check balance increased by amount
                require(postBalance - preBalance == amount, "Balance did not increase by borrow amount");
            }
        }
    }

    // BORROWING_HSPOST_J: After a successful borrow the onBehalf debt balance should increase by the amount borrowed
    function assertBorrowDebtChanges() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (, uint256 amount,,, address onBehalfOf) =
                abi.decode(callInputs[i].input, (address, uint256, uint256, uint16, address));

            // Get debt before
            ph.forkPreState();
            (, uint256 totalDebtBase,,,,) = pool.getUserAccountData(onBehalfOf);

            // Get debt after
            ph.forkPostState();
            (, uint256 postTotalDebtBase,,,,) = pool.getUserAccountData(onBehalfOf);

            // Check debt increased by at least the borrow amount (could be more due to interest)
            require(postTotalDebtBase > totalDebtBase, "Debt did not increase");
            require(postTotalDebtBase - totalDebtBase >= amount, "Debt increase should be at least the borrow amount");
        }
    }

    // BORROWING_HSPOST_K: After a successful repay the actor asset balance should decrease by the amount repaid
    function assertRepayBalanceChanges() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (address asset, uint256 amount,,) = abi.decode(callInputs[i].input, (address, uint256, uint256, address));

            // Get underlying token
            IERC20 underlying = IERC20(asset);

            // Get balances before
            ph.forkPreState();
            uint256 preBalance = underlying.balanceOf(callInputs[i].caller);

            // Get balances after
            ph.forkPostState();
            uint256 postBalance = underlying.balanceOf(callInputs[i].caller);

            // Check balance decreased by amount
            require(preBalance - postBalance == amount, "Balance did not decrease by repay amount");
        }
    }

    // BORROWING_HSPOST_L: After a successful repay the onBehalf debt balance should decrease by at least the amount repaid
    function assertRepayDebtChanges() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.repay.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (, uint256 amount,, address onBehalfOf) =
                abi.decode(callInputs[i].input, (address, uint256, uint256, address));

            // Get debt before
            ph.forkPreState();
            (, uint256 totalDebtBase,,,,) = pool.getUserAccountData(onBehalfOf);

            // Get debt after
            ph.forkPostState();
            (, uint256 postTotalDebtBase,,,,) = pool.getUserAccountData(onBehalfOf);

            // Check debt decreased by at least the repay amount (could be more due to interest)
            require(totalDebtBase > postTotalDebtBase, "Debt did not decrease");
            require(totalDebtBase - postTotalDebtBase >= amount, "Debt decrease should be at least the repay amount");
        }
    }
}
