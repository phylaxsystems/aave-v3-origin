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

  function testAssertionBorrowBug() public {
    // For testing purposes, we have introduced a bug in the borrow function
    // When trying to borrow exactly 333e6, the user will receive double the amount
    // and the total debt will not be correctly updated

    // Use a fresh user (bob) to avoid conflicts with alice's existing state
    address freshUser = bob;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowingPostConditionAssertions).creationCode,
      abi.encode(pool)
    );

    // Set up fresh user with collateral
    deal(asset, freshUser, 2000e6);
    vm.startPrank(freshUser);
    underlying.approve(address(pool), type(uint256).max);
    pool.supply(asset, 1000e6, freshUser, 0); // Supply collateral first

    vm.expectRevert('Assertions Reverted');
    // This should fail assertions because the user will receive double tokens
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(
        pool.borrow.selector,
        asset,
        333e6, // borrow the evil amount
        DataTypes.InterestRateMode.VARIABLE,
        0,
        freshUser
      )
    );
    vm.stopPrank();
  }

  function testFoundryBorrowBug() public {
    uint256 evilAmount = 333e6;
    address freshUser = bob; // Use fresh user

    // Set up user with enough balance to supply collateral
    deal(asset, freshUser, 2000e6);
    vm.startPrank(freshUser);
    underlying.approve(address(pool), type(uint256).max);
    pool.supply(asset, 1000e6, freshUser, 0);

    // Get balances and debt before borrowing (use debt token for consistent units)
    uint256 balanceBefore = underlying.balanceOf(freshUser);
    uint256 debtBefore = variableDebtToken.balanceOf(freshUser);
    emit log_named_uint('User balance before borrow', balanceBefore);
    emit log_named_uint('User debt before borrow (debt token)', debtBefore);

    // Borrow the evil amount
    pool.borrow(asset, evilAmount, 2, 0, freshUser);

    // Get balances and debt after borrowing (use debt token for consistent units)
    uint256 balanceAfter = underlying.balanceOf(freshUser);
    uint256 debtAfter = variableDebtToken.balanceOf(freshUser);
    emit log_named_uint('User balance after borrow', balanceAfter);
    emit log_named_uint('User debt after borrow (debt token)', debtAfter);

    // Check that the user received double the amount
    assertEq(
      balanceAfter - balanceBefore,
      evilAmount * 2,
      'User did not receive double the borrowed amount'
    );
    // Check that the debt only increased by the evil amount (using debt token balance)
    assertEq(debtAfter - debtBefore, evilAmount, 'Debt did not increase by the borrowed amount');
    vm.stopPrank();
  }

  function testFoundryBorrowBugUnderlyingBalance() public {
    uint256 evilAmount = 333e6;
    address freshUser = bob; // Use fresh user

    // Set up user with enough balance to supply collateral
    deal(asset, freshUser, 2000e6);
    vm.startPrank(freshUser);
    underlying.approve(address(pool), type(uint256).max);
    pool.supply(asset, 1000e6, freshUser, 0);

    // Get underlying balance before borrowing
    uint256 balanceBefore = underlying.balanceOf(freshUser);
    emit log_named_uint('Underlying balance before borrow', balanceBefore);

    // Borrow the evil amount
    pool.borrow(asset, evilAmount, 2, 0, freshUser);

    // Get underlying balance after borrowing
    uint256 balanceAfter = underlying.balanceOf(freshUser);
    emit log_named_uint('Underlying balance after borrow', balanceAfter);

    // The user should receive double the amount
    assertEq(
      balanceAfter - balanceBefore,
      evilAmount * 2,
      'User did not receive double the borrowed amount'
    );

    // Get debt after borrowing (for reference)
    (, uint256 debtAfter, , , , ) = pool.getUserAccountData(freshUser);
    emit log_named_uint('User debt after borrow', debtAfter);

    vm.stopPrank();
  }

  function testFoundryBorrowBugTotalDebt() public {
    uint256 evilAmount = 333e6;
    address freshUser = bob; // Use fresh user

    // Set up user with enough balance to supply collateral
    deal(asset, freshUser, 2000e6);
    vm.startPrank(freshUser);
    underlying.approve(address(pool), type(uint256).max);
    pool.supply(asset, 1000e6, freshUser, 0);

    // Get total debt before borrowing (via variable debt token)
    uint256 totalDebtBefore = variableDebtToken.totalSupply();
    emit log_named_uint('Total debt before borrow', totalDebtBefore);

    // Get user balance before borrowing
    uint256 balanceBefore = underlying.balanceOf(freshUser);
    emit log_named_uint('User balance before borrow', balanceBefore);

    // Borrow the evil amount
    pool.borrow(asset, evilAmount, 2, 0, freshUser);

    // Get total debt after borrowing
    uint256 totalDebtAfter = variableDebtToken.totalSupply();
    emit log_named_uint('Total debt after borrow', totalDebtAfter);

    // Get user balance after borrowing
    uint256 balanceAfter = underlying.balanceOf(freshUser);
    emit log_named_uint('User balance after borrow', balanceAfter);

    // Calculate the actual debt increase
    uint256 debtIncrease = totalDebtAfter - totalDebtBefore;
    emit log_named_uint('Actual debt increase', debtIncrease);

    // Calculate tokens received by user
    uint256 tokensReceived = balanceAfter - balanceBefore;
    emit log_named_uint('Tokens received by user', tokensReceived);

    // Show the bug: user gets double tokens
    assertEq(tokensReceived, evilAmount * 2, 'User did not receive double tokens');

    // Show the bug: debt only increases by original amount
    assertEq(debtIncrease, evilAmount, 'Debt did not increase by original amount');

    // VERIFY the bug: Debt increase should NOT equal tokens issued (this demonstrates the bug)
    assertTrue(
      debtIncrease != tokensReceived,
      'Bug not present: debt increase equals tokens issued'
    );

    vm.stopPrank();
  }

  // See test/BrokenRepayPool.t.sol for cases that trigger the assertions
  // We have to use a mock pool to test these cases
}
