// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {IPoolAddressesProvider} from '../../src/contracts/interfaces/IPoolAddressesProvider.sol';
import {IAaveOracle} from '../../src/contracts/interfaces/IAaveOracle.sol';
import {OracleAssertions} from '../src/production/OracleAssertions.a.sol';
import {IMockL2Pool} from '../src/interfaces/IMockL2Pool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';
import {MockAggregator} from '../../src/contracts/mocks/oracle/CLAggregators/MockAggregator.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';

contract OracleAssertionsTest is CredibleTest, Test, TestnetProcedures {
  IPoolAddressesProvider public addressesProvider;
  IAaveOracle public oracle;
  IMockL2Pool public pool;
  L2Encoder public l2Encoder;
  address public asset;
  MockAggregator public priceFeed;
  IERC20 public underlying;
  IERC20 public variableDebtToken;
  OracleAssertions public assertions;
  string public constant ASSERTION_LABEL = 'OracleAssertions';

  function setUp() public {
    // Initialize test environment with real contracts (L2 enabled for L2Encoder)
    initL2TestEnvironment();

    // Deploy mock token
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Get variable debt token
    (, , address variableDebtUSDX) = contracts.protocolDataProvider.getReserveTokensAddresses(
      asset
    );
    variableDebtToken = IERC20(variableDebtUSDX);

    int256 price = 10e8;

    // Deploy mock price feed with price of 100 USD (8 decimals)
    priceFeed = new MockAggregator(price);

    // Deploy oracle
    address[] memory assets = new address[](1);
    address[] memory sources = new address[](1);
    assets[0] = address(asset);
    sources[0] = address(priceFeed);

    oracle = contracts.aaveOracle;

    vm.prank(poolAdmin);
    oracle.setAssetSources(assets, sources);

    // Set up pool reference
    pool = IMockL2Pool(report.poolProxy);

    // Set up L2Encoder for creating compact parameters
    l2Encoder = L2Encoder(report.l2Encoder);

    // Deploy assertions contract
    assertions = new OracleAssertions(address(oracle), address(pool));

    // Setup initial positions
    vm.startPrank(alice);
    // Supply collateral
    underlying.approve(address(pool), type(uint256).max);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 1000e6, 0);
    pool.supply(supplyArgs);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 500e6, 2, 0);
    pool.borrow(borrowArgs);

    // Ensure alice has enough tokens to repay
    underlying.transfer(alice, 1000e6);
    vm.stopPrank();
  }

  function testAssertionBorrowPriceDeviation() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(OracleAssertions).creationCode,
      abi.encode(address(oracle), address(pool))
    );

    // Set user as the caller
    vm.startPrank(alice);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);

    // This should pass because price hasn't deviated
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function testAssertionSupplyPriceDeviation() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(OracleAssertions).creationCode,
      abi.encode(address(oracle), address(pool))
    );

    // Set user as the caller
    vm.startPrank(alice);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 100e6, 0);

    // This should pass because price hasn't deviated
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }
}
