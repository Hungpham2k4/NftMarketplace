// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
// Dùng để sử dụng chấp nhận thanh toán cho nhiều ERC20 khác nhau
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract Marketplace is Ownable {
    using Counters for Counters.Counter;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct Order {
        address seller;
        address buyer;
        uint256 tokenId;
        address paymentToken;
        uint256 price;
    }

    // Lưu current Id hiện tại
    Counters.Counter private _orderIdCount;

    IERC721 public immutable nftContract;
    mapping(uint256 => Order) orders;

    // % phí sẽ trở thành giá trị số nguyên để tìm ra giá trị cuối
    uint256 public feeDecimal;
    uint256 public feeRate;
    // Địa chỉ ví nhận phí giao dịch của nftmk
    address public feeRecipient;
    // Biến dùng để lưu hết các địa chỉ của các token mà contract mảketplae support
    EnumerableSet.AddressSet private _supportedPaymentTokens;

    // Các event ====== keyword index(dùng để bắt các event có tên là OrderAdded trong 1 khoảng block)
    event OrderAdded(
        uint256 indexed orderId,
        address indexed seller,
        uint256 indexed tokenId,
        address paymentToken,
        uint256 price
    );
    event OrderCancelled(uint256 indexed orderId);
    event OrderMatched(
        uint256 indexed orderId,
        address indexed seller,
        address indexed buyer,
        uint256 tokenId,
        address paymentToken,
        uint256 price
    );
    // event dùng khi các fee của smartcontract đc update
    event FeeRateUpdated(uint256 feeDecimal, uint256 feeRate);

    constructor(
        address nftAddress_,
        uint256 feeDecimal_,
        uint256 feeRate_,
        address feeRecipient_
    ) {
        require(
            nftAddress_ != address(0),
            "NFTMarketplace: nftAddress_ is zero address"
        );

        nftContract = IERC721(nftAddress_);
        _updateFeeRecipient(feeRecipient_);
        _updateFeeRate(feeDecimal_, feeRate_);
        _orderIdCount.increment();
    }

    // Dùng trong cóntructor
    function _updateFeeRecipient(address feeRecipient_) internal {
        require(
            feeRecipient_ != address(0),
            "NFTMarketplace: feeRecipient_ is zero address"
        );
        feeRecipient = feeRecipient_;
    }

    // Dùng cả ra bên ngoài, onlyOwner(Chỉ owner mới có quyền)
    function updateFeeRecipient(address feeRecipient_) external onlyOwner {
        _updateFeeRecipient(feeRecipient_);
    }

    function _updateFeeRate(uint256 feeDecimal_, uint256 feeRate_) internal {
        require(
            feeRate_ < 10 ** (feeDecimal_ + 2),
            "NFTMarketplace: bad fee rate"
        );
        feeDecimal = feeDecimal_;
        feeRate = feeRate_;
        emit FeeRateUpdated(feeDecimal_, feeRate_);
    }

    function updateFeeRate(
        uint256 feeDecimal_,
        uint256 feeRate_
    ) external onlyOwner {
        _updateFeeRate(feeDecimal_, feeRate_);
    }

    // Lấy % giá trị order của orderID
    function _calculateFee(uint256 orderId_) private view returns (uint256) {
        Order storage _order = orders[orderId_];
        if (feeRate == 0) {
            return 0;
        }
        return (feeRate * _order.price) / 10 ** (feeDecimal + 2);
        // vd: (10 * 100 * 10^18 ) / 10^2
    }

    // Check orderId có phải thuộc về người bán không
    function isSeller(
        uint256 orderId_,
        address seller_
    ) public view returns (bool) {
        return orders[orderId_].seller == seller_;
    }

    // support payment 
    function addPaymentToken(address paymentToken_) external onlyOwner {
        require(
            paymentToken_ != address(0),
            "NFTMarketplace: feeRecipient_ is zero address"
        );
        // Trả về true nếu đc add thành công/ nếu fall thì sẽ bắn ra
        require(
            _supportedPaymentTokens.add(paymentToken_),
            "NFTMarketplace: already supported"
        );
    }

    // Check xem address của token này đã đc add vào paymentToken hay chưa
    function isPaymentTokenSupported(
        address paymentToken_
    ) public view returns (bool) {
        return _supportedPaymentTokens.contains(paymentToken_);
    }

    modifier onlySupportedPaymentToken(address paymentToken_) {
        require(
            isPaymentTokenSupported(paymentToken_),
            "NFTMarketplace: unsupport payment token"
        );
        _; //Thể hiện là dòng code tiếp theo
    }

    function addOrder(
        uint256 tokenId_,
        address paymentToken_,
        uint256 price_
    ) public onlySupportedPaymentToken(paymentToken_) {
        require(
            nftContract.ownerOf(tokenId_) == _msgSender(),
            "NFTMarketplace: sender is not owner of token"
        );
        require(
            nftContract.getApproved(tokenId_) == address(this) ||
                nftContract.isApprovedForAll(_msgSender(), address(this)),
            "NFTMarketplace: The contract is unauthorized to manage this token"
        );
        require(price_ > 0, "NFTMarketplace: price must be greater than 0");
        uint256 _orderId = _orderIdCount.current(); //Truy cập vào order thông qua orderid
        orders[_orderId] = Order(
            _msgSender(), //NGười đăng bán
            address(0), //Buyer
            tokenId_,
            paymentToken_,
            price_
        );
        _orderIdCount.increment();
        nftContract.transferFrom(_msgSender(), address(this), tokenId_);
        emit OrderAdded(
            _orderId,
            _msgSender(),
            tokenId_,
            paymentToken_,
            price_
        );
    }

    function cancelOrder(uint256 orderId_) external {
        Order storage _order = orders[orderId_];
        // order này phải chưa được bán
        require(
            _order.buyer == address(0),
            "NFTMarketplace: buyer must be zero"
        );
        // và phải là người chủ
        require(_order.seller == _msgSender(), "NFTMarketplace: must be owner");
        uint256 _tokenId = _order.tokenId;
        delete orders[orderId_];
        // chuyển từ nftmarketplace về ví của ng cancel 
        nftContract.transferFrom(address(this), _msgSender(), _tokenId);
        emit OrderCancelled(orderId_);
    }

    function executeOrder(uint256 orderId_) external {
        Order storage _order = orders[orderId_];
        require(_order.price > 0, "NFTMarketplace: order has been canceled");
        //Người mua phải khác người bán
        require(
            !isSeller(orderId_, _msgSender()),
            "NFTMarketplace: buyer must be different from seller"
        );
        // Kiểm tra order này bị mua chưa
        require(
            _order.buyer == address(0),
            "NFTMarketplace: buyer must be zero"
        );
        _order.buyer = _msgSender();
        uint256 _feeAmount = _calculateFee(orderId_);
        if (_feeAmount > 0) {
            IERC20(_order.paymentToken).transferFrom(
                _msgSender(),
                feeRecipient,
                _feeAmount
            );
        }
        IERC20(_order.paymentToken).transferFrom(
            _msgSender(),
            _order.seller,
            _order.price - _feeAmount
        );
        nftContract.transferFrom(address(this), _msgSender(), _order.tokenId);
        emit OrderMatched(
            orderId_,
            _order.seller,
            _order.buyer,
            _order.tokenId,
            _order.paymentToken,
            _order.price
        );
    }
}
