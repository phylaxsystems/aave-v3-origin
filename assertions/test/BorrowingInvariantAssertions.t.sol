// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title BorrowingInvariantAssertions Tests
 * @notice This test file uses the real Aave V3 protocol to verify that our assertions
 *         correctly pass when the protocol behaves as expected. It ensures that our
 *         assertions don't revert when they shouldn't, validating that our invariant
 *         checks are not overly restrictive.
 *
 *         For example, it verifies that the liability decrease assertion passes when
 *         a user successfully repays their debt, as the real protocol correctly
 *         decreases the user's debt.
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {BorrowingPostConditionAssertions} from '../src/BorrowingInvariantAssertions.a.sol';
import {IMockPool} from '../src/IMockPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';

contract TestBorrowingInvariantAssertions is CredibleTest, Test, TestnetProcedures {
  IMockPool public pool;
  BorrowingPostConditionAssertions public assertions;
  address public user;
  address public asset;
  IERC20 public underlying;
  IERC20 public variableDebtToken;
  string public constant ASSERTION_LABEL = 'BorrowingInvariantAssertions';

  function setUp() public {
    // Initialize test environment with real contracts
    initTestEnvironment();

    // Set up user and get pool reference
    user = alice;
    pool = IMockPool(report.poolProxy);
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Deploy assertions contract
    assertions = new BorrowingPostConditionAssertions(pool);

    // Get variable debt token
    (, , address variableDebtUSDX) = contracts.protocolDataProvider.getReserveTokensAddresses(
      asset
    );
    variableDebtToken = IERC20(variableDebtUSDX);

    // Setup initial positions
    vm.startPrank(user);
    // Supply collateral
    underlying.approve(address(pool), type(uint256).max);
    pool.supply(asset, 1000e6, user, 0);
    // Borrow some amount
    pool.borrow(asset, 500e6, 2, 0, user);
    // Ensure user has enough tokens to repay
    underlying.transfer(user, 1000e6);
    vm.stopPrank();
  }

  function testAssertionLiabilityDecrease() public {
    uint256 repayAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowingPostConditionAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller and ensure enough allowance
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // This should pass because debt will decrease
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(
        pool.repay.selector,
        asset,
        repayAmount,
        DataTypes.InterestRateMode.VARIABLE,
        user
      )
    );
    vm.stopPrank();
  }

  function testLiabilityDecreaseRegular() public {
    uint256 repayAmount = 100e6;

    // Set up user with enough balance to repay (matching setUp)
    deal(asset, user, 1000e6);

    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral (matching setUp)
    pool.supply(asset, 1000e6, user, 0);

    // Borrow some amount (matching setUp)
    pool.borrow(asset, 500e6, 2, 0, user);

    // Get debt before repayment
    (, uint256 preDebt, , , , ) = pool.getUserAccountData(user);

    // Repay some tokens
    pool.repay(asset, repayAmount, 2, user);

    // Get debt after repayment
    (, uint256 postDebt, , , , ) = pool.getUserAccountData(user);

    // Verify debt decreased
    assertTrue(postDebt < preDebt, 'Debt did not decrease after repayment');
    assertTrue(
      preDebt - postDebt >= repayAmount,
      'Debt decrease should be at least the repay amount'
    );

    vm.stopPrank();
  }

  function testAssertionUnhealthyBorrowPrevention() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowingPostConditionAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller
    vm.startPrank(user);

    // This should pass because the user is healthy (has sufficient collateral)
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
        user
      )
    );
    vm.stopPrank();
  }

  // See test/BrokenRepayPool.t.sol for cases that trigger the assertions
  // We have to use a mock pool to test these cases
}
