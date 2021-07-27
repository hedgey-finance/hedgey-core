contract HedgeyCallDealsV1 is ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    
    address payable public weth = ; //insert weth address here
    uint public fee;
    address payable public feeCollector;
    bool public feeCollectorSet;
    uint public d = 1;
    
    

    constructor(address payable _feeCollector, uint _fee, bool _feeCollectorSet) public {
        feeCollector = _feeCollector;
        fee = _fee;
        feeCollectorSet = _feeCollectorSet;
    }

    
    struct ArchDeal {
        address asset;
        bool assetWeth;
        address paymentCurrency;
        bool paymentWeth;
        uint c;
        mapping (uint => Deal) deals;
    }
    
    mapping (uint => ArchDeal) public archdeals;
  
    mapping(address => mapping(address => uint)) public dealpairs;


    struct Deal {
        address payable creator;
        address payable recipient;
        uint assetAmount;
        uint strike;
        uint price;
        uint totalPurchase;
        uint feeAmount;
        uint expiry;
        uint vestDate;
        bool claimed;
        bool exercised;
        bool closed;
    }


    receive() external payable {    
    }

    function depositPymt(bool _isWeth, address _token, address _sender, uint _amt) internal {
        if (_isWeth) {
            require(msg.value == _amt, "deposit issue: sending in wrong amount of eth");
            IWETH(weth).deposit{value: _amt}();
            assert(IWETH(weth).transfer(address(this), _amt));
        } else {
            SafeERC20.safeTransferFrom(IERC20(_token), _sender, address(this), _amt);
        }
    }

    function withdrawPymt(bool _isWeth, address _token, address payable to, uint _amt) internal {
        if (_isWeth && (!Address.isContract(to))) {
            //if the address is a contract - then we should actually just send WETH out to the contract, else send the wallet eth
            IWETH(weth).withdraw(_amt);
            to.transfer(_amt);
        } else {
            SafeERC20.safeTransfer(IERC20(_token), to, _amt);
        }
    }

    function transferPymt(bool _isWETH, address _token, address from, address payable to, uint _amt) internal {
        if (_isWETH) {
            if (!Address.isContract(to)) {
                to.transfer(_amt);
            } else {
                // we want to deliver WETH from ETH here for better handling at contract
                IWETH(weth).deposit{value: _amt}();
                assert(IWETH(weth).transfer(to, _amt));
            }
        } else {
            SafeERC20.safeTransferFrom(IERC20(_token), from, to, _amt);         
        }
    }



    function getDealInfo(uint _d, uint _c) external view returns (address creator, address recipient, uint assetAmount, uint strike, bool claimed, bool exercised, bool closed) {
        ArchDeal storage a = archdeals[_d];
        Deal storage call = a.deals[_c];
        creator = call.creator;
        recipient = call.recipient;
        assetAmount = call.assetAmount;
        strike = call.strike;
        claimed = call.claimed;
        exercised = call.exercised;
        closed = call.closed;
    }


    //core call functions - creator / seller

    function createArchDeal(address _asset, address _paymentCurrency) public {
        //this function just sets up the overall struct to then make subdeals
        require(dealpairs[_asset][_paymentCurrency] == 0, "this dealpair already exists");
        bool assetWeth;
        bool pymtWeth;
        if (_asset == weth) {
            assetWeth = true;
            pymtWeth = false;
        } else if (_paymentCurrency == weth) {
            assetWeth = false;
            pymtWeth = true;
        } else {
            assetWeth = false;
            pymtWeth = false;
        }
        dealpairs[_asset][_paymentCurrency] = d;
        archdeals[d++] = ArchDeal(_asset, assetWeth, _paymentCurrency, pymtWeth, 0);
        emit ArchDealCreated(d.sub(1), _asset, _paymentCurrency);
    }

    //create deal
    function createDeal(
        uint _d,
        address payable _recipient, 
        uint _assetAmount, 
        uint _strike,
        uint _price,
        uint _expiry,
        uint _vestDate
        ) payable public {
            ArchDeal storage a = archdeals[_d];
            require(msg.sender != _recipient, "cant assign this to yourself");
            uint assetDecimals = IERC20(a.asset).decimals();
            uint _totalPurchase = _assetAmount.mul(_strike).div(10 ** assetDecimals);
            require(_totalPurchase > 0, "c: totalPurchase error: too small amount");
            uint _feeAmount = _assetAmount.mul(fee).div(1e4);
            uint _totalLocked = _assetAmount.add(_feeAmount);
            uint balCheck = a.assetWeth ? msg.value : IERC20(a.asset).balanceOf(msg.sender);
            require(balCheck >= _totalLocked, "c: not enough to sell this call option");
            depositPymt(a.assetWeth, a.asset, msg.sender, _totalLocked);
            a.deals[a.c++] = Deal(
                msg.sender, 
                _recipient, 
                _assetAmount, 
                _strike, 
                _price, 
                _totalPurchase,
                _feeAmount,
                _expiry,
                _vestDate,
                false,
                false,
                false
                );
            emit DealCreated(a.c.sub(1), _recipient, _assetAmount, _strike, _price, _expiry, _vestDate);

        } 

    //cancel deal

    function cancelDeal(uint _d, uint _c) payable public nonReentrant {
        ArchDeal storage a = archdeals[_d];
        Deal storage call = a.deals[_c];
        require(msg.sender == call.creator, "c: you are not the creator");
        require(!call.exercised, "c: already exercised deal");
        require(!call.closed, "c: deal already closed");
        require(!call.claimed || (call.expiry < now), "c: deal claimed or has not expired");
        call.closed = true;
        withdrawPymt(a.assetWeth, a.asset, call.creator, call.assetAmount.add(call.feeAmount));
        emit DealCancelled(_c);
    } 


    //recipient functions

    //claim deal
    function claimDeal(uint _d, uint _c) payable public nonReentrant {
        ArchDeal storage a = archdeals[_d];
        Deal storage call = a.deals[_c];
        require(msg.sender != call.creator, "c: you created this");
        require(msg.sender == call.recipient, "c: you are not the intended recipient");
        require(!call.exercised, "c: already exercised deal");
        require(!call.closed, "c: deal already closed");
        require(!call.claimed || (call.expiry > now), "c: deal claimed or has expired");
        call.claimed = true;
        transferPymt(a.paymentWeth, a.paymentCurrency, msg.sender, call.creator, call.price);
        withdrawPymt(a.assetWeth, a.asset, feeCollector, call.feeAmount);
        if (feeCollectorSet) {
            IHedgeyStaking(feeCollector).receiveFee(call.feeAmount, a.paymentCurrency);
        }
        emit DealClaimed(_c);
    }

    //exercise deal
    function exerciseDeal(uint _d, uint _c) payable public nonReentrant {
        ArchDeal storage a = archdeals[_d];
        Deal storage call = a.deals[_c];
        require(msg.sender != call.creator, "c: you created this");
        require(msg.sender == call.recipient, "c: only recipient");
        require(!call.exercised, "c: already exercised deal");
        require(!call.closed, "c: deal already closed");
        require(call.claimed, "c: deal hasnt been claimed yet");
        require(call.vestDate <= now && call.expiry >= now, "c: deal not vested or has expired");
        uint balCheck = a.paymentWeth ? msg.value : IERC20(a.paymentCurrency).balanceOf(msg.sender);
        require(balCheck >= call.totalPurchase, "balance issue: insufficient funds to exercise this deal");
        call.exercised = true;
        call.closed = true;
        //deliver cash from recipient to creator, and asset from smart contract to recipient
        transferPymt(a.paymentWeth, a.paymentCurrency, msg.sender, call.creator, call.totalPurchase);
        withdrawPymt(a.assetWeth, a.asset, msg.sender, call.assetAmount);
        emit DealExercised(_c);
    }

    //events
    event ArchDealCreated(uint _i, address _asset, address _paymentCurrency);
    event DealCreated(uint _i, address payable _recipient, uint _assetAmount, uint _strike, uint _price, uint _expiry, uint _vestDate);
    event DealCancelled(uint _i);
    event DealClaimed(uint _i);
    event DealExercised(uint _i);
}
