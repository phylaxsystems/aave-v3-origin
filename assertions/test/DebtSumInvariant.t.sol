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
import {BaseInvariants} from '../src/BaseInvariants.a.sol';
import {IMockPool} from '../src/IMockPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';

contract TestBorrowingInvariantAssertions is CredibleTest, Test, TestnetProcedures {
  IMockPool public pool;
  BaseInvariants public assertions;
  address public user;
  address public asset;
  IERC20 public underlying;
  IERC20 public variableDebtToken;
  string public constant ASSERTION_LABEL = 'DebtSumInvariant';

  function setUp() public {
    // Initialize test environment with real contracts
    initTestEnvironment();

    // Set up user and get pool reference
    user = alice;
    pool = IMockPool(report.poolProxy);
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Deploy assertions contract
    assertions = new BaseInvariants(address(pool), asset);

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
      type(BaseInvariants).creationCode,
      abi.encode(address(pool), asset)
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
}
