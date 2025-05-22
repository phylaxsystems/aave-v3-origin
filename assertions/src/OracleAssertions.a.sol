// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from "credible-std/Assertion.sol";
import {PhEvm} from "credible-std/PhEvm.sol";
import {IAaveOracle} from "../../src/contracts/interfaces/IAaveOracle.sol";
import {IPoolAddressesProvider} from "../../src/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "../../src/contracts/interfaces/IPool.sol";

/**
 * @title OracleAssertions
 * @notice Assertions for Aave V3 oracle price checks
 */
contract OracleAssertions is Assertion {
    IAaveOracle public immutable oracle;
    IPool public immutable pool;
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 500; // 5% max deviation

    constructor(address oracleAddress, address poolAddress) {
        oracle = IAaveOracle(oracleAddress);
        pool = IPool(poolAddress);
    }

    function triggers() public view override {
        // Register triggers for core operations that affect oracle prices
        registerCallTrigger(this.assertBorrowPriceDeviation.selector, pool.borrow.selector);
        registerCallTrigger(this.assertSupplyPriceDeviation.selector, pool.supply.selector);
        registerCallTrigger(this.assertLiquidationPriceDeviation.selector, pool.liquidationCall.selector);
    }

    /**
     * @notice Asserts that the price of an asset has not deviated by more than the maximum allowed percentage during borrow
     */
    function assertBorrowPriceDeviation() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.borrow.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (address asset,,,,) = abi.decode(callInputs[i].input, (address, uint256, uint256, uint16, address));
            _checkPriceDeviation(asset, "Borrow price deviation exceeds maximum allowed");
        }
    }

    /**
     * @notice Asserts that the price of an asset has not deviated by more than the maximum allowed percentage during supply
     */
    function assertSupplyPriceDeviation() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.supply.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (address asset,,,) = abi.decode(callInputs[i].input, (address, uint256, address, uint16));
            _checkPriceDeviation(asset, "Supply price deviation exceeds maximum allowed");
        }
    }

    /**
     * @notice Asserts that the price of collateral and debt assets has not deviated by more than the maximum allowed percentage during liquidation
     */
    function assertLiquidationPriceDeviation() external {
        PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(address(pool), pool.liquidationCall.selector);
        for (uint256 i = 0; i < callInputs.length; i++) {
            (address collateralAsset, address debtAsset,,,) =
                abi.decode(callInputs[i].input, (address, address, address, uint256, bool));
            _checkPriceDeviation(collateralAsset, "Collateral price deviation exceeds maximum allowed");
            _checkPriceDeviation(debtAsset, "Debt price deviation exceeds maximum allowed");
        }
    }

    /**
     * @notice Internal helper to check price deviation for an asset
     * @param asset The address of the asset to check
     * @param errorMessage The error message to use if deviation is too high
     */
    function _checkPriceDeviation(address asset, string memory errorMessage) internal {
        // Get price before
        ph.forkPreState();
        uint256 prePrice = oracle.getAssetPrice(asset);

        // Get price after
        ph.forkPostState();
        uint256 postPrice = oracle.getAssetPrice(asset);

        // Skip check if prices are 0
        require(prePrice != 0 && postPrice != 0, "Oracle returned zero price");

        // Calculate deviation in basis points
        uint256 deviation;
        if (postPrice > prePrice) {
            deviation = ((postPrice - prePrice) * 10000) / prePrice;
        } else {
            deviation = ((prePrice - postPrice) * 10000) / prePrice;
        }

        // Check deviation is within limits
        require(deviation <= MAX_PRICE_DEVIATION_BPS, "oracle price deviation exceeds maximum allowed");
    }
}
