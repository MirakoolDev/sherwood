// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PonsFeeSplitter, IPonsLocker, IWETH} from "./PonsFeeSplitter.sol";

/// @notice The part of a Pons-launched token (PonsLauncherToken) the factory reads.
interface IPonsToken {
    function deployer() external view returns (address);
    function launchFactory() external view returns (address);
    function pairToken() external view returns (address);
}

/// @title Pons fee splitter factory
/// @notice Lets any token launched on Pons get its own PonsFeeSplitter: the same contract that splits $PFWA's
/// creator fees, so every copy verifies against the same source. Each token gets one splitter, made by the wallet
/// that launched the token (the only wallet Pons lets redirect its fees), at an address that depends only on the
/// token, owner and treasury, so it can be computed before it exists. After create, that wallet points the
/// token's fees at the splitter on Pons (setFeeRedirect on the locker) and, as the splitter's owner, sets its pot
/// (setPot) and the pot's share (setPotShare, half to start). The factory takes no fee and keeps no control: it
/// owns nothing it makes.
contract PonsFeeSplitterFactory {
    /// @notice Pons' launch locker, which holds every launch's LP and pays out its fees.
    IPonsLocker public immutable locker;
    IWETH public immutable weth;
    /// @notice Pons' launch factory: only tokens it made can get a splitter here.
    address public immutable ponsFactory;

    /// @notice The splitter made here for each token (zero: none yet).
    mapping(address token => address) public splitterOf;
    address[] internal _splitters;

    event SplitterCreated(address indexed token, address indexed splitter, address indexed owner, address treasury);

    error NotPonsToken();
    error NotTokenDeployer();
    error NotWethPair();
    error AlreadyCreated();
    error ZeroAddress();

    constructor(IPonsLocker _locker, IWETH _weth, address _ponsFactory) {
        locker = _locker;
        weth = _weth;
        ponsFactory = _ponsFactory;
    }

    /// @notice Makes `token`'s splitter. Only the wallet that launched `token` on Pons can call this, once.
    /// `owner` sets the pot and its share later; `treasury` gets the rest of the ETH and all the token.
    function create(address token, address owner, address treasury) external returns (address splitter) {
        if (owner == address(0) || treasury == address(0)) revert ZeroAddress();
        if (splitterOf[token] != address(0)) revert AlreadyCreated();
        IPonsToken t = IPonsToken(token);
        address launchedBy;
        try t.launchFactory() returns (address f) {
            if (f != ponsFactory) revert NotPonsToken();
            launchedBy = t.deployer();
        } catch {
            revert NotPonsToken();
        }
        if (msg.sender != launchedBy) revert NotTokenDeployer();
        // The splitter unwraps the locker's WETH; a launch paired with anything else would leave it stuck.
        if (t.pairToken() != address(weth)) revert NotWethPair();
        splitter = address(new PonsFeeSplitter{salt: _salt(token)}(locker, weth, token, owner, treasury));
        splitterOf[token] = splitter;
        _splitters.push(splitter);
        emit SplitterCreated(token, splitter, owner, treasury);
    }

    /// @notice Where create(token, owner, treasury) puts the splitter (also before it exists).
    function predict(address token, address owner, address treasury) external view returns (address) {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(PonsFeeSplitter).creationCode, abi.encode(locker, weth, token, owner, treasury))
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(token), initHash)))));
    }

    /// @notice How many splitters were made here.
    function count() external view returns (uint256) {
        return _splitters.length;
    }

    /// @notice The splitters made here, `start` to `start + n` (clamped).
    function page(uint256 start, uint256 n) external view returns (address[] memory out) {
        uint256 end = start + n > _splitters.length ? _splitters.length : start + n;
        out = new address[](end > start ? end - start : 0);
        for (uint256 i; i < out.length; ++i) out[i] = _splitters[start + i];
    }

    function _salt(address token) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(token)));
    }
}
