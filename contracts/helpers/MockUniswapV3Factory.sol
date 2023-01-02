// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.13;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { Token } from "../token/Token.sol";
import { TokenLibrary } from "../token/TokenLibrary.sol";

import { Utils } from "../utility/Utils.sol";

import { MockUniswapV3Pool } from "./MockUniswapV3Pool.sol";

contract MockUniswapV3Factory is Utils {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    MockUniswapV3Pool private immutable _pool;

    EnumerableSet.AddressSet private _tokens;

    constructor(MockUniswapV3Pool pool) {
        _pool = pool;
    }

    function getPair(address token0, address token1) external view returns (address) {
        if (_tokens.contains(token0) && _tokens.contains(token1)) {
            return address(_pool);
        }
        return address(0);
    }

    function setTokens(address token0, address token1) external {
        _tokens.add(token0);
        _tokens.add(token1);
    }
}
