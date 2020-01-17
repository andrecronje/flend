pragma solidity ^0.5.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Mintable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../interface/FPrice.sol";
import "../interface/SFC.sol";

contract LiquidityPool is ReentrancyGuard {
    using SafeMath for uint256;
    using Address for address;
    using SafeERC20 for ERC20;

    struct EpochSnapshot {
        uint256 endTime;
        uint256 duration;
        uint256 feePool;
    }

    uint256 currentEpoch;
    mapping(uint256 => EpochSnapshot) public epochSnapshots; // written by consensus outside

    function _makeEpochSnapshot() external {
      currentEpoch++;
      EpochSnapshot storage newSnapshot = epochSnapshots[currentEpoch];
      newSnapshot.endTime = block.timestamp;
      if (currentEpoch == 0) {
          newSnapshot.duration = 0;
      } else {
          newSnapshot.duration = block.timestamp - epochSnapshots[currentEpoch - 1].endTime;
      }
      newSnapshot.feePool = feePool;
      feePool = 0;
    }


    uint256 public feePool;

    // Collateral data
    mapping(address => mapping(address => uint256)) public _collateral;
    mapping(address => mapping(address => uint256)) public _collateralTokens;
    mapping(address => address[]) public _collateralList;
    //Collateral measured in fUSD
    mapping(address => uint256) public _collateralValue;

    // Debt data
    mapping(address => mapping(address => uint256)) public _debt;
    mapping(address => mapping(address => uint256)) public _debtTokens;
    mapping(address => address[]) public _debtList;
    // Debt measured in fUSD
    mapping(address => uint256) public _debtValue;

    // Claimed balances
    mapping (address => uint256) public _claimedEpoch;
    mapping (address => uint256) public _claimed;

    //native denom address
    function fAddress() internal pure returns(address) {
        return 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    }

    //ftmAddress
    function SFCAddress() internal pure returns(address) {
        return 0xFC00FACE00000000000000000000000000000000;
    }

    //oracleAddress
    function oAddress() internal pure returns(address) {
        return 0xC17518AE5dAD82B8fc8b56Fe0295881c30848829;
    }

    //fUSD
    function fUSD() internal pure returns(address) {
        return 0xC17518AE5dAD82B8fc8b56Fe0295881c30848829;
    }

    // Tracks list of user collateral
    function addCollateralToList(address _token, address _owner) internal {
        bool tokenAlreadyAdded = false;
        address[] memory tokenList = _collateralList[_owner];
        for (uint256 i = 0; i < tokenList.length; i++)
            if (tokenList[i] == _token) {
                tokenAlreadyAdded = true;
            }
        if (!tokenAlreadyAdded) _collateralList[_owner].push(_token);
    }

    // Tracks list of user debt
    function addDebtToList(address _token, address _owner) internal {
        bool tokenAlreadyAdded = false;
        address[] memory tokenList = _debtList[_owner];
        for (uint256 i = 0; i < tokenList.length; i++)
            if (tokenList[i] == _token) {
                tokenAlreadyAdded = true;
            }
        if (!tokenAlreadyAdded) _debtList[_owner].push(_token);
    }

    event Claim(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    event Deposit(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    event Withdraw(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    event Borrow(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    event Repay(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    event Mint(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    event Burn(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    event Buy(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _price,
        uint256 _timestamp
    );

    event Sell(
        address indexed _token,
        address indexed _user,
        uint256 _amount,
        uint256 _price,
        uint256 _timestamp
    );

    // Calculate the current collateral value of all assets for user
    function calcCollateralValue(address addr) public view returns(uint256 collateralValue)
    {
        for (uint i = 0; i < _collateralList[addr].length; i++) {
          uint256 results = IFPrice(oAddress()).getPrice(_collateralList[addr][i]);
          collateralValue = collateralValue.add(results);
        }
        collateralValue = collateralValue.div(2);
    }

    // Calculate the current debt value of all assets for user
    function calcDebtValue(address addr) public view returns(uint256 debtValue)
    {
      for (uint i = 0; i < _debtList[addr].length; i++) {
        uint256 results = IFPrice(oAddress()).getPrice(_debtList[addr][i]);
        debtValue = debtValue.add(results);
      }
    }

    // Claim rewards in fUSD off of locked native denom
    // Fee 0.25%
    function claimDelegationRewards(uint256 maxEpochs) external nonReentrant {
        // Get current fUSD value of native denom
        uint256 tokenValue = IFPrice(oAddress()).getPrice(fAddress());
        require(tokenValue > 0, "native denom has no value");

        uint256 fromEpoch = _claimedEpoch[msg.sender];
        (uint256 pendingRewards, , uint256 untilEpoch) = SFC(SFCAddress()).calcDelegationRewards(fromEpoch, 0, maxEpochs);
        require(pendingRewards > 0, "no pending rewards");

        _claimed[msg.sender] = pendingRewards.add(_claimed[msg.sender]);
        _claimedEpoch[msg.sender] = untilEpoch;

        // 300% collateral value
        uint256 _amount = rewards.mul(tokenValue).div(3);
        uint256 fee = _amount.mul(25).div(10000);
        feePool = feePool.add(fee);

        // Mint 50% worth of fUSD and transfer
        ERC20Mintable(fUSD()).mint(address(this), _amount);
        ERC20(fUSD()).safeTransfer(msg.sender, _amount.sub(fee));

        emit Claim(fUSD(), msg.sender, _amount, block.timestamp);
    }

    // Claim validator rewards in fUSD off of locked native denom
    // Fee 0.25%
    function claimValidatorRewards(uint256 maxEpochs) external nonReentrant {
        uint256 tokenValue = IFPrice(oAddress()).getPrice(fAddress());
        require(tokenValue > 0, "native denom has no value");

        uint256 fromEpoch = _claimedEpoch[msg.sender];
        uint256 stakerID = SFC(SFCAddress()).getStakerID(msg.sender);
        (uint256 pendingRewards, , uint256 untilEpoch) = SFC(SFCAddress()).calcValidatorRewards(stakerID, 0, maxEpochs);
        require(pendingRewards > 0 "no pending rewards");

        _claimed[msg.sender] = pendingRewards.add(_claimed[msg.sender]);
        _claimedEpoch[msg.sender] = untilEpoch;

        uint256 _amount = rewards.mul(tokenValue).div(3);
        uint256 fee = _amount.mul(25).div(10000);
        feePool = feePool.add(fee);

        ERC20Mintable(fUSD()).mint(address(this), _amount);
        ERC20(fUSD()).safeTransfer(msg.sender, _amount.sub(fee));

        emit Claim(fUSD(), msg.sender, _amount, block.timestamp);
    }

    // Deposit assets as collateral
    // No fee, gain interest on deposited value
    function deposit(address _token, uint256 _amount)
        external
        payable
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");

        // Mapping of token => users
        // Mapping of users => tokens

        _collateral[_token][msg.sender] = _collateral[_token][msg.sender].add(_amount);
        _collateralTokens[msg.sender][_token] = _collateralTokens[msg.sender][_token].add(_amount);
        addCollateralToList(_token, msg.sender);

        _collateralValue[msg.sender] = calcCollateralValue(msg.sender);

        // Non native denom
        if (_token != fAddress()) {
            require(msg.value == 0, "user is sending native denom along with the token transfer.");
            ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        } else {
            require(msg.value >= _amount, "the amount and the value sent to deposit do not match");
            if (msg.value > _amount) {
                uint256 excessAmount = msg.value.sub(_amount);
                (bool result, ) = msg.sender.call.value(excessAmount).gas(50000)("");
                require(result, "transfer of ETH failed");
            }
        }
        emit Deposit(_token, msg.sender, _amount, block.timestamp);
    }

    // Withdraw any deposited collateral that has a value from the contract
    // No fee
    function withdraw(address _token, uint256 _amount)
        external
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");

        _collateral[_token][msg.sender] = _collateral[_token][msg.sender].sub(_amount, "withdraw amount exceeds balance");
        _collateralTokens[msg.sender][_token] = _collateralTokens[msg.sender][_token].sub(_amount, "withdraw amount exceeds balance");

        uint256 collateralValue = calcCollateralValue(msg.sender);
        uint256 debtValue = calcDebtValue(msg.sender);

        require(collateralValue > debtValue, "withdraw would liquidate holdings");

        _collateralValue[msg.sender] = collateralValue;
        _debtValue[msg.sender] = debtValue;

        if (_token != fAddress()) {
            uint256 balance = ERC20(_token).balanceOf(address(this));
            if (balance < _amount) {
              ERC20Mintable(_token).mint(address(this), _amount.sub(balance));
            }
            ERC20(_token).safeTransfer(msg.sender, _amount);
        } else {
            (bool result, ) = msg.sender.call.value(_amount).gas(50000)("");
            require(result, "transfer of ETH failed");
        }
        emit Withdraw(_token, msg.sender, _amount, block.timestamp);
    }

    // Fee 0.25%
    // Can't buy or sell native denom or fUSD
    function buy(address _token, uint256 _amount)
        external
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");
        require(_token != fAddress(), "native denom");
        require(_token != fUSD(), "fusd denom");

        uint256 tokenValue = IFPrice(oAddress()).getPrice(_token);
        require(tokenValue > 0, "token has no value");

        uint256 buyValue = _amount.mul(tokenValue);
        uint256 fee = buyValue.mul(25).div(10000);
        uint256 buyValueIncFee = buyValue.add(fee);
        uint256 balance = ERC20(fUSD()).balanceOf(msg.sender);
        require(balance >= buyValueIncFee, "insufficient funds");

        // Claim fUSD
        ERC20(fUSD()).safeTransferFrom(msg.sender, address(this), buyValueIncFee);

        // Mint and transfer token
        ERC20Mintable(_token).mint(address(this), _amount);
        ERC20(_token).safeTransfer(msg.sender, _amount);

        feePool = feePool.add(fee);

        emit Buy(_token, msg.sender, _amount, tokenValue, block.timestamp);
    }

    // Sell an owned asset for fusd
    // Fee 0.25%
    // Can't buy or sell native denom or fUSD
    function sell(address _token, uint256 _amount)
        external
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");
        require(_token != fAddress(), "native denom");
        require(_token != fUSD(), "fusd denom");

        uint256 balance = ERC20(_token).balanceOf(msg.sender);
        require(balance >= _amount, "insufficient funds");

        uint256 tokenValue = IFPrice(oAddress()).getPrice(_token);
        require(tokenValue > 0, "token has no value");

        uint256 sellValue = _amount.mul(tokenValue);

        // Claim token
        ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // Mint and transfer fUSD
        balance = ERC20(_token).balanceOf(address(this));
        if (balance < sellValue) {
          // Mint fUSD and increase global debt
          // This is the value of fUSD to native denom ratio
          // totalSupply(fUSD) / 2 = claimable value of native denom
          ERC20Mintable(fUSD()).mint(address(this), sellValue.sub(balance));
        }
        uint256 fee = sellValue.mul(25).div(10000);
        feePool = feePool.add(fee);
        ERC20(fUSD()).safeTransfer(msg.sender, sellValue.sub(fee));

        emit Sell(_token, msg.sender, _amount, tokenValue, block.timestamp);
    }

    // Fee 4% per annum
    // Initiation fee 0.25% of total value
    function borrow(address _token, uint256 _amount)
        external
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");
        require(_token != fAddress(), "native denom not borrowable");
        require(_collateralValue[msg.sender] > 0, "collateral must be greater than 0");

        uint256 tokenValue = IFPrice(oAddress()).getPrice(_token);
        require(tokenValue > 0, "debt token has no value");

        // Calculate 0.25% initiation fee
        uint256 fee = _amount.mul(tokenValue).mul(25).div(10000);
        feePool = feePool.add(fee);
        _debt[fUSD()][msg.sender] = _debt[fUSD()][msg.sender].add(fee);
        _debtTokens[msg.sender][fUSD()] = _debtTokens[msg.sender][fUSD()].add(fee);
        addDebtToList(fUSD(), msg.sender);

        _debt[_token][msg.sender] = _debt[_token][msg.sender].add(_amount);
        _debtTokens[msg.sender][_token] = _debtTokens[msg.sender][_token].add(_amount);
        addDebtToList(_token, msg.sender);

        uint256 collateralValue = calcCollateralValue(msg.sender);
        uint256 debtValue = calcDebtValue(msg.sender);

        require(collateralValue > debtValue, "insufficient collateral");

        _collateralValue[msg.sender] = collateralValue;
        _debtValue[msg.sender] = debtValue;

        uint256 balance = ERC20(_token).balanceOf(address(this));
        if (balance < _amount) {
          ERC20Mintable(_token).mint(address(this), _amount.sub(balance));
        }
        ERC20(_token).safeTransfer(msg.sender, _amount);

        emit Borrow(_token, msg.sender, _amount, block.timestamp);
    }

    // Fee 6% per annum
    // Initiation fee 0.25% of total value
    /*function mint(address _token, uint256 _amount)
        external
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");
        require(_collateralValue[msg.sender] > 0, "collateral must be greater than 0");
        require(_token != fAddress(), "native denom");
        require(_token != fUSD(), "fusd denom");

        uint256 tokenValue = IFPrice(oAddress()).getPrice(_token);
        require(tokenValue > 0, "token has no value");

        // Calculate 0.25% initiation fee
        uint256 fee = _amount.mul(tokenValue).mul(25).div(10000);
        feePool = feePool.add(fee);
        _debt[fUSD()][msg.sender] = _debt[fUSD()][msg.sender].add(fee);
        _debtTokens[msg.sender][fUSD()] = _debtTokens[msg.sender][fUSD()].add(fee);
        addDebtToList(fUSD(), msg.sender);

        // Accure debt into debt values
        _debt[_token][msg.sender] = _debt[_token][msg.sender].add(_amount);
        _debtTokens[msg.sender][_token] = _debtTokens[msg.sender][_token].add(_amount);
        addDebtToList(_token, msg.sender);

        uint256 collateralValue = calcCollateralValue(msg.sender);
        uint256 debtValue = calcDebtValue(msg.sender);

        require(collateralValue > debtValue, "insufficient collateral");

        _collateralValue[msg.sender] = collateralValue;
        _debtValue[msg.sender] = debtValue;

        ERC20Mintable(_token).mint(address(this), _amount);
        ERC20(_token).safeTransfer(msg.sender, _amount);

        emit Mint(_token, msg.sender, _amount, block.timestamp);
    }*/

    // No fee
    /*function burn(address _token, uint256 _amount)
        external
        payable
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");
        require(_token != fAddress(), "native denom");

        _debt[_token][msg.sender] = _debt[_token][msg.sender].sub(_amount, "insufficient debt outstanding");
        _debtTokens[msg.sender][_token] = _debtTokens[msg.sender][_token].sub(_amount, "insufficient debt outstanding");

        _collateralValue[msg.sender] = calcCollateralValue(msg.sender);
        _debtValue[msg.sender] = calcDebtValue(msg.sender);

        ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        emit Burn(_token, msg.sender, _amount, block.timestamp);
    }*/

    // No fee
    function repay(address _token, uint256 _amount)
        external
        payable
        nonReentrant
    {
        require(_amount > 0, "amount must be greater than 0");
        require(_token != fAddress(), "native denom not borrowable");


        _debt[_token][msg.sender] = _debt[_token][msg.sender].sub(_amount, "insufficient debt outstanding");
        _debtTokens[msg.sender][_token] = _debtTokens[msg.sender][_token].sub(_amount, "insufficient debt outstanding");

        _collateralValue[msg.sender] = calcCollateralValue(msg.sender);
        _debtValue[msg.sender] = calcDebtValue(msg.sender);

        require(msg.value == 0, "user is sending ETH along with the ERC20 transfer.");
        ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        emit Repay(_token, msg.sender, _amount, block.timestamp);
    }

    function liquidate(address _owner)
        external
        nonReentrant
    {
        _collateralValue[_owner] = calcCollateralValue(_owner);
        _debtValue[_owner] = calcDebtValue(_owner);

        require(_collateralValue[_owner] < _debtValue[_owner], "insufficient debt to liquidate");

        for (uint i = 0; i < _collateralList[_owner].length; i++) {
          _collateral[_collateralList[_owner][i]][_owner] = _collateral[_collateralList[_owner][i]][_owner].sub(_collateralTokens[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
          _collateralTokens[_owner][_collateralList[_owner][i]] = _collateralTokens[_owner][_collateralList[_owner][i]].sub(_collateralTokens[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
        }

        for (uint i = 0; i < _debtList[_owner].length; i++) {
          _debt[_collateralList[_owner][i]][_owner] = _debt[_collateralList[_owner][i]][_owner].sub(_debt[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
          _debtTokens[_owner][_collateralList[_owner][i]] = _debtTokens[_owner][_collateralList[_owner][i]].sub(_debtTokens[_owner][_collateralList[_owner][i]], "liquidation exceeds balance");
        }

        _collateralValue[_owner] = calcCollateralValue(_owner);
        _debtValue[_owner] = calcDebtValue(_owner);
    }

    function liquidateToken(address _owner, address _token)
        external
        nonReentrant
    {
        _collateralValue[_owner] = calcCollateralValue(_owner);
        _debtValue[_owner] = calcDebtValue(_owner);

        require(_collateralValue[_owner] < _debtValue[_owner], "insufficient debt to liquidate");

        _collateral[_token][_owner] = _collateral[_token][_owner].sub(_collateralTokens[_owner][_token], "liquidation exceeds balance");
        _collateralTokens[_owner][_token] = _collateralTokens[_owner][_token].sub(_collateralTokens[_owner][_token], "liquidation exceeds balance");

        _debt[_token][_owner] = _debt[_token][_owner].sub(_debt[_owner][_token], "liquidation exceeds balance");
        _debtTokens[_owner][_token] = _debtTokens[_owner][_token].sub(_debtTokens[_owner][_token], "liquidation exceeds balance");

        _collateralValue[_owner] = calcCollateralValue(_owner);
        _debtValue[_owner] = calcDebtValue(_owner);
    }
}
