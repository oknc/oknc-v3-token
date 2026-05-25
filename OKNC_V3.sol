// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPancakeRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external;
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract OKNCV3 is ERC20, Ownable, ReentrancyGuard {
    using Address for address payable;

    uint256 constant BUY_FEE = 100;
    uint256 constant SELL_FEE = 100;
    uint256 constant TRANSFER_FEE = 50;
    uint256 constant FEE_DENOMINATOR = 10000;

    address constant ECOSYSTEM_WALLET = 0x050493685cd466a7be41FA8275334dCAb105A54C;
    address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public oldToken;

    uint256 constant MAGNIFIER = 2**128;
    uint256 constant TOTAL_SUPPLY = 21_000_000_000 * 10**18;
    uint256 constant BURN_AMOUNT = 18_900_000_000 * 10**18;

    IPancakeRouter public pancakeRouter;
    address public pancakePair;
    uint256 public swapThreshold;
    bool public swapEnabled;
    bool private _inSwap;
    uint256 public accumulatedForDividends;
    uint256 public totalDividendBalance;
    uint256 public totalDividendPerToken;
    mapping(address => uint256) public dividendWithdraw;
    uint256 public totalRewardDistributed;
    mapping(address => bool) public isExcludedFromFee;
    mapping(address => bool) public isExcludedFromDividend;
    bool public swapFromOldEnabled;
    uint256 public totalMigrated;

    event SwapAndSendDividend(uint256,uint256,uint256);
    event FeeCollected(address indexed,uint256,uint256);
    event ClaimDividend(address indexed,uint256);
    event SwapThresholdUpdated(uint256);
    event SwapFromOld(address indexed,uint256,uint256);
    event SwapFromOldEnabledSet(bool);
    event OldTokensWithdrawn(address indexed,uint256);
    event TokensBurned(uint256);

    modifier lockSwap() { _inSwap = true; _; _inSwap = false; }

    constructor() ERC20("OKNC Token", "OKNC") Ownable(msg.sender) {
        pancakeRouter = IPancakeRouter(PANCAKE_ROUTER);
        pancakePair = IPancakeFactory(pancakeRouter.factory()).createPair(address(this), pancakeRouter.WETH());
        isExcludedFromFee[address(this)] = true;
        isExcludedFromFee[ECOSYSTEM_WALLET] = true;
        isExcludedFromFee[owner()] = true;
        isExcludedFromFee[address(0)] = true;
        isExcludedFromFee[BURN_ADDRESS] = true;
        isExcludedFromDividend[address(0)] = true;
        isExcludedFromDividend[BURN_ADDRESS] = true;
        isExcludedFromDividend[pancakePair] = true;
        isExcludedFromDividend[address(pancakeRouter)] = true;
        isExcludedFromDividend[address(this)] = true;
        swapThreshold = 21_000_000 * 10**18;

        // 核心修复：铸造 210亿到合约 → 销毁 189亿 → 剩余 21亿为置换池
        _mint(address(this), TOTAL_SUPPLY);
        _transfer(address(this), BURN_ADDRESS, BURN_AMOUNT);
        emit TokensBurned(BURN_AMOUNT);
    }

    receive() external payable {}

    function pendingDividend(address account) public view returns (uint256) {
        if (isExcludedFromDividend[account] || balanceOf(account) == 0) return 0;
        uint256 totalReward = (balanceOf(account) * totalDividendPerToken) / MAGNIFIER;
        uint256 claimed = dividendWithdraw[account];
        if (totalReward <= claimed) return 0;
        return totalReward - claimed;
    }

    function swapPoolBalance() public view returns (uint256) { return balanceOf(address(this)); }

    function setSwapThreshold(uint256 t) external onlyOwner {
        require(t > 0, "zero"); swapThreshold = t; emit SwapThresholdUpdated(t);
    }
    function setSwapEnabled(bool e) external onlyOwner { swapEnabled = e; }
    function manualSwapAndDistribute() external onlyOwner { _swapAndDistribute(accumulatedForDividends); }
    function rescueBNB(uint256 amt) external onlyOwner {
        require(amt <= address(this).balance, "insuff"); payable(msg.sender).sendValue(amt);
    }
    function withdrawToken(address token, uint256 amt) external onlyOwner {
        require(amt > 0, "zero");
        IERC20(token).transfer(msg.sender, amt);
    }
    function setOldToken(address t) external onlyOwner {
        require(t != address(0), "invalid"); require(address(oldToken) == address(0), "set"); oldToken = t;
    }
    function setExcludedFromFee(address a, bool e) external onlyOwner { isExcludedFromFee[a] = e; }
    function setExcludedFromDividend(address a, bool e) external onlyOwner { isExcludedFromDividend[a] = e; }
    function setSwapFromOldEnabled(bool e) external onlyOwner {
        swapFromOldEnabled = e; emit SwapFromOldEnabledSet(e);
    }

    // 修复版 swapFromOld：从合约余额转账，不增发
    function swapFromOld(uint256 amount) external {
        require(swapFromOldEnabled, "disabled");
        require(amount > 0, "zero");
        IERC20(oldToken).transferFrom(msg.sender, address(this), amount);
        IERC20(oldToken).transfer(BURN_ADDRESS, amount);
        uint256 newAmount = amount * 10**10;
        require(balanceOf(address(this)) >= newAmount, "pool depleted");
        _transfer(address(this), msg.sender, newAmount);
        totalMigrated += amount;
        emit SwapFromOld(msg.sender, amount, newAmount);
    }


    // —— V2→V3 临时兑换 ——
    address public v2Token;
    bool public v2ToV3SwapEnabled;
    uint256 public totalV2Migrated;
    event SwapV2ForV3(address indexed user, uint256 amount);
    event V2ToV3SwapEnabledSet(bool enabled);

    function setV2Token(address _v2Token) external onlyOwner {
        require(_v2Token != address(0), "invalid");
        require(address(v2Token) == address(0), "set");
        v2Token = _v2Token;
    }

    function setV2ToV3SwapEnabled(bool enabled) external onlyOwner {
        v2ToV3SwapEnabled = enabled;
        emit V2ToV3SwapEnabledSet(enabled);
    }

    /// @notice V2 代币 1:1 兑换 V3（仅限今天，之后永久关闭）
    function swapV2ForV3(uint256 amount) external {
        require(v2ToV3SwapEnabled, "disabled");
        require(amount > 0, "zero");
        require(balanceOf(address(this)) >= amount, "pool depleted");
        IERC20(v2Token).transferFrom(msg.sender, address(this), amount);
        IERC20(v2Token).transfer(BURN_ADDRESS, amount);
        _transfer(address(this), msg.sender, amount);
        totalV2Migrated += amount;
        emit SwapV2ForV3(msg.sender, amount);
    }

    function withdrawOldToken(uint256 amt) external onlyOwner {
        require(amt > 0, "zero"); IERC20(oldToken).transfer(msg.sender, amt);
        emit OldTokensWithdrawn(msg.sender, amt);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) { super._update(from, to, amount); return; }
        require(amount > 0, "zero");
        (uint256 fee, uint256 feeType) = _calculateFee(from, to, amount);
        uint256 transferAmount = amount - fee;
        if (fee > 0) {
            super._update(from, address(this), fee);
            if (feeType == 1) { accumulatedForDividends += fee; emit FeeCollected(from, fee, 1); }
            else if (feeType == 2) { super._update(address(this), ECOSYSTEM_WALLET, fee); emit FeeCollected(from, fee, 2); }
            else if (feeType == 3) { super._update(address(this), ECOSYSTEM_WALLET, fee); emit FeeCollected(from, fee, 3); }
        }
        super._update(from, to, transferAmount);
        _updateDividendAccounting(from);
        _updateDividendAccounting(to);
        if (feeType == 1 && !_inSwap && swapEnabled && accumulatedForDividends >= swapThreshold)
            _swapAndDistribute(accumulatedForDividends);
    }

    function _calculateFee(address from, address to, uint256 amount) internal view returns (uint256 fee, uint256 feeType) {
        if (isExcludedFromFee[from] || isExcludedFromFee[to]) return (0, 0);
        if (from == pancakePair) { fee = (amount * BUY_FEE) / FEE_DENOMINATOR; feeType = 1; }
        else if (to == pancakePair) { fee = (amount * SELL_FEE) / FEE_DENOMINATOR; feeType = 2; }
        else { fee = (amount * TRANSFER_FEE) / FEE_DENOMINATOR; feeType = 3; }
    }

    function _swapAndDistribute(uint256 tokenAmount) internal nonReentrant lockSwap {
        require(tokenAmount > 0 && tokenAmount <= accumulatedForDividends, "bad");
        accumulatedForDividends -= tokenAmount;
        _approve(address(this), address(pancakeRouter), tokenAmount);
        uint256 bal = address(this).balance;
        address[] memory path = new address[](2);
        path[0] = address(this); path[1] = pancakeRouter.WETH();
        try pancakeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp+300
        ) {
            uint256 received = address(this).balance - bal;
            if (received > 0) { _distributeDividend(received); emit SwapAndSendDividend(tokenAmount, received, received); }
        } catch { accumulatedForDividends += tokenAmount; }
    }

    function _distributeDividend(uint256 amt) internal {
        if (amt == 0 || totalSupply() == 0) return;
        uint256 excluded = 0;
        if (isExcludedFromDividend[pancakePair]) excluded += balanceOf(pancakePair);
        if (isExcludedFromDividend[address(this)]) excluded += balanceOf(address(this));
        if (isExcludedFromDividend[ECOSYSTEM_WALLET]) excluded += balanceOf(ECOSYSTEM_WALLET);
        uint256 effective = totalSupply() - excluded;
        if (effective == 0) return;
        totalDividendPerToken += (amt * MAGNIFIER) / effective;
        totalDividendBalance += amt;
    }

    function claimDividend() external nonReentrant { _claimDividend(msg.sender); }
    function claimDividendBatch(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++)
            if (pendingDividend(accounts[i]) > 0) _claimDividend(accounts[i]);
    }
    function _claimDividend(address account) internal {
        uint256 pending = pendingDividend(account);
        require(pending > 0, "none"); require(address(this).balance >= pending, "bnb");
        dividendWithdraw[account] += pending;
        totalRewardDistributed += pending;
        totalDividendBalance -= pending;
        payable(account).sendValue(pending);
        emit ClaimDividend(account, pending);
    }
    function _updateDividendAccounting(address account) internal {
        if (account == address(0) || isExcludedFromDividend[account]) return;
        uint256 pending = pendingDividend(account);
        if (pending > 0) dividendWithdraw[account] = (balanceOf(account) * totalDividendPerToken) / MAGNIFIER;
    }
}
