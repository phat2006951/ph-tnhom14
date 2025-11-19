/* =========================================================
   HotelDB – Quản lý đặt phòng khách sạn (SQL Server)
   Sao chép toàn bộ script này và chạy trong SSMS
   ========================================================= */

-- 1) Tạo database và schema
IF DB_ID('HotelDB') IS NULL
BEGIN
  CREATE DATABASE HotelDB;
END
GO

USE HotelDB;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'hotel')
BEGIN
  EXEC('CREATE SCHEMA hotel AUTHORIZATION dbo;');
END
GO

/* 2) Xóa đối tượng cũ (nếu tồn tại) để đảm bảo clean run */

IF OBJECT_ID('hotel.usp_CancelBooking', 'P') IS NOT NULL DROP PROCEDURE hotel.usp_CancelBooking;
IF OBJECT_ID('hotel.usp_CreateBooking', 'P') IS NOT NULL DROP PROCEDURE hotel.usp_CreateBooking;
IF OBJECT_ID('hotel.ufn_IsRoomAvailable', 'FN') IS NOT NULL DROP FUNCTION hotel.ufn_IsRoomAvailable;

IF OBJECT_ID('hotel.Payments', 'U') IS NOT NULL DROP TABLE hotel.Payments;
IF OBJECT_ID('hotel.Bookings', 'U') IS NOT NULL DROP TABLE hotel.Bookings;
IF OBJECT_ID('hotel.Guests', 'U') IS NOT NULL DROP TABLE hotel.Guests;
IF OBJECT_ID('hotel.Rooms', 'U') IS NOT NULL DROP TABLE hotel.Rooms;
IF OBJECT_ID('hotel.RoomTypes', 'U') IS NOT NULL DROP TABLE hotel.RoomTypes;
GO

/* 3) Tạo bảng danh mục */

CREATE TABLE hotel.RoomTypes (
  RoomTypeID INT IDENTITY(1,1) PRIMARY KEY,
  TypeName NVARCHAR(50) NOT NULL UNIQUE,
  BasePrice DECIMAL(18,2) NOT NULL CHECK (BasePrice >= 0),
  MaxGuests INT NOT NULL CHECK (MaxGuests > 0)
);
GO

CREATE TABLE hotel.Rooms (
  RoomID INT IDENTITY(1,1) PRIMARY KEY,
  RoomNumber NVARCHAR(20) NOT NULL UNIQUE,
  RoomTypeID INT NOT NULL,
  Status NVARCHAR(20) NOT NULL DEFAULT N'AVAILABLE'
    CHECK (Status IN (N'AVAILABLE', N'OUT_OF_SERVICE')),
  CONSTRAINT FK_Rooms_RoomTypes FOREIGN KEY (RoomTypeID)
    REFERENCES hotel.RoomTypes(RoomTypeID)
);
GO

CREATE TABLE hotel.Guests (
  GuestID INT IDENTITY(1,1) PRIMARY KEY,
  FullName NVARCHAR(100) NOT NULL,
  Phone NVARCHAR(20) NOT NULL,
  Email NVARCHAR(255) NULL,
  DocumentNo NVARCHAR(50) NULL
);
GO

/* 4) Tạo bảng nghiệp vụ */

CREATE TABLE hotel.Bookings (
  BookingID INT IDENTITY(1,1) PRIMARY KEY,
  GuestID INT NOT NULL,
  RoomID INT NOT NULL,
  CheckIn DATE NOT NULL,
  CheckOut DATE NOT NULL,
  Status NVARCHAR(20) NOT NULL DEFAULT N'PENDING'
    CHECK (Status IN (N'PENDING', N'CONFIRMED', N'CHECKED_IN', N'CHECKED_OUT', N'CANCELLED')),
  Adults INT NOT NULL CHECK (Adults > 0),
  Children INT NOT NULL DEFAULT 0 CHECK (Children >= 0),
  NightlyRate DECIMAL(18,2) NOT NULL CHECK (NightlyRate >= 0),
  CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  CONSTRAINT FK_Bookings_Guests FOREIGN KEY (GuestID) REFERENCES hotel.Guests(GuestID),
  CONSTRAINT FK_Bookings_Rooms FOREIGN KEY (RoomID) REFERENCES hotel.Rooms(RoomID),
  CONSTRAINT CK_Bookings_Date CHECK (CheckIn < CheckOut)
);
GO

CREATE TABLE hotel.Payments (
  PaymentID INT IDENTITY(1,1) PRIMARY KEY,
  BookingID INT NOT NULL,
  Amount DECIMAL(18,2) NOT NULL CHECK (Amount > 0),
  Method NVARCHAR(20) NOT NULL CHECK (Method IN (N'CASH', N'CARD', N'BANK')),
  PaidAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
  Note NVARCHAR(200) NULL,
  CONSTRAINT FK_Payments_Bookings FOREIGN KEY (BookingID) REFERENCES hotel.Bookings(BookingID)
);
GO

/* 5) Chỉ mục tối ưu */

CREATE INDEX IX_Bookings_Room_Date 
ON hotel.Bookings (RoomID, CheckIn, CheckOut, Status);
GO

CREATE INDEX IX_Guests_Phone_Email 
ON hotel.Guests (Phone, Email);
GO

CREATE INDEX IX_Payments_Booking_PaidAt 
ON hotel.Payments (BookingID, PaidAt);
GO

/* 6) Dữ liệu mẫu */

INSERT INTO hotel.RoomTypes (TypeName, BasePrice, MaxGuests)
VALUES (N'Standard', 800000, 2),
       (N'Deluxe',   1200000, 3),
       (N'Suite',    2200000, 4);
GO

INSERT INTO hotel.Rooms (RoomNumber, RoomTypeID)
VALUES (N'101', 1), (N'102', 1), (N'201', 2), (N'202', 2), (N'301', 3);
GO

INSERT INTO hotel.Guests (FullName, Phone, Email, DocumentNo)
VALUES (N'Nguyễn Văn A', N'0901234567', N'a.nguyen@example.com', N'012345678'),
       (N'Trần Thị B',   N'0912345678', N'b.tran@example.com',   N'987654321');
GO

INSERT INTO hotel.Bookings (GuestID, RoomID, CheckIn, CheckOut, Status, Adults, Children, NightlyRate)
VALUES (1, 1, '2025-11-20', '2025-11-23', N'CONFIRMED', 2, 0, 800000);
GO

/* 7) Hàm kiểm tra phòng trống */

CREATE OR ALTER FUNCTION hotel.ufn_IsRoomAvailable (
  @RoomID INT,
  @CheckIn DATE,
  @CheckOut DATE
)
RETURNS BIT
AS
BEGIN
  IF EXISTS (
    SELECT 1
    FROM hotel.Bookings b
    WHERE b.RoomID = @RoomID
      AND b.Status IN (N'CONFIRMED', N'CHECKED_IN')
      AND b.CheckIn < @CheckOut
      AND b.CheckOut > @CheckIn
  )
    RETURN 0;
  RETURN 1;
END;
GO

/* 8) Thủ tục tạo booking an toàn */

CREATE OR ALTER PROCEDURE hotel.usp_CreateBooking
  @GuestID INT,
  @RoomID INT,
  @CheckIn DATE,
  @CheckOut DATE,
  @Adults INT,
  @Children INT = 0,
  @NightlyRate DECIMAL(18,2),
  @BookingID INT OUTPUT
AS
BEGIN
  SET NOCOUNT ON;

  IF @CheckIn >= @CheckOut
  BEGIN
    RAISERROR (N'CheckIn phải trước CheckOut', 16, 1);
    RETURN;
  END

  -- Kiểm tra sức chứa
  DECLARE @MaxGuests INT;
  SELECT @MaxGuests = rt.MaxGuests
  FROM hotel.Rooms r
  JOIN hotel.RoomTypes rt ON rt.RoomTypeID = r.RoomTypeID
  WHERE r.RoomID = @RoomID;

  IF @MaxGuests IS NULL
  BEGIN
    RAISERROR (N'RoomID không hợp lệ', 16, 1);
    RETURN;
  END

  IF (@Adults + ISNULL(@Children,0)) > @MaxGuests
  BEGIN
    RAISERROR (N'Vượt quá sức chứa của phòng', 16, 1);
    RETURN;
  END

  BEGIN TRAN;

  -- Khóa logic để tránh đặt trùng do concurrent transactions
  IF EXISTS (
    SELECT 1
    FROM hotel.Bookings WITH (UPDLOCK, HOLDLOCK)
    WHERE RoomID = @RoomID
      AND Status IN (N'CONFIRMED', N'CHECKED_IN')
      AND CheckIn < @CheckOut
      AND CheckOut > @CheckIn
  )
  BEGIN
    ROLLBACK TRAN;
    RAISERROR (N'Phòng không còn trống trong khoảng thời gian này', 16, 1);
    RETURN;
  END
  INSERT INTO hotel.Bookings (GuestID, RoomID, CheckIn, CheckOut, Status, Adults, Children, NightlyRate)
  VALUES (@GuestID, @RoomID, @CheckIn, @CheckOut, N'CONFIRMED', @Adults, @Children, @NightlyRate);

  SET @BookingID = SCOPE_IDENTITY();

  COMMIT TRAN;
END;
GO

/* 9) Thủ tục hủy booking + hoàn tiền đơn giản */

CREATE OR ALTER PROCEDURE hotel.usp_CancelBooking
  @BookingID INT,
  @RefundAmount DECIMAL(18,2) = 0
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @status NVARCHAR(20);
  SELECT @status = Status FROM hotel.Bookings WHERE BookingID = @BookingID;

  IF @status IS NULL
  BEGIN
    RAISERROR (N'Không tìm thấy Booking', 16, 1);
    RETURN;
  END

  IF @status IN (N'CHECKED_IN', N'CHECKED_OUT')
  BEGIN
    RAISERROR (N'Không thể hủy sau khi đã nhận/trả phòng', 16, 1);
    RETURN;
  END

  BEGIN TRAN;

  UPDATE hotel.Bookings
  SET Status = N'CANCELLED'
  WHERE BookingID = @BookingID;

  IF @RefundAmount > 0
  BEGIN
    INSERT INTO hotel.Payments (BookingID, Amount, Method, Note)
    VALUES (@BookingID, -@RefundAmount, N'BANK', N'Refund on cancel');
  END

  COMMIT TRAN;
END;
GO

/* 10) Truy vấn thường dùng (tham khảo) */

-- Tìm phòng trống theo khoảng ngày
DECLARE @from DATE = '2025-11-21';
DECLARE @to   DATE = '2025-11-22';

SELECT r.RoomID, r.RoomNumber, rt.TypeName, rt.BasePrice, rt.MaxGuests
FROM hotel.Rooms r
JOIN hotel.RoomTypes rt ON rt.RoomTypeID = r.RoomTypeID
WHERE r.Status = N'AVAILABLE'
AND NOT EXISTS (
  SELECT 1
  FROM hotel.Bookings b
  WHERE b.RoomID = r.RoomID
    AND b.Status IN (N'CONFIRMED', N'CHECKED_IN')
    AND b.CheckIn < @to
    AND b.CheckOut > @from
)
ORDER BY rt.BasePrice, r.RoomNumber;
GO

-- Tính số đêm và tổng tiền booking
SELECT b.BookingID,
       DATEDIFF(DAY, b.CheckIn, b.CheckOut) AS Nights,
       b.NightlyRate * DATEDIFF(DAY, b.CheckIn, b.CheckOut) AS TotalPrice
FROM hotel.Bookings b;
GO

-- Công suất phòng theo một ngày
DECLARE @date DATE = '2025-11-21';
SELECT rt.TypeName,
       COUNT(*) AS TotalRooms,
       SUM(CASE 
            WHEN EXISTS (
              SELECT 1 FROM hotel.Bookings b
              WHERE b.RoomID = r.RoomID
                AND b.Status IN (N'CONFIRMED', N'CHECKED_IN')
                AND b.CheckIn <= @date AND b.CheckOut > @date
            ) THEN 1 ELSE 0 END) AS OccupiedRooms
FROM hotel.Rooms r
JOIN hotel.RoomTypes rt ON rt.RoomTypeID = r.RoomTypeID
GROUP BY rt.TypeName;
GO

-- Doanh thu theo tháng
SELECT FORMAT(p.PaidAt, 'yyyy-MM') AS YearMonth,
       SUM(p.Amount) AS Revenue
FROM hotel.Payments p
GROUP BY FORMAT(p.PaidAt, 'yyyy-MM')
ORDER BY YearMonth;
GO

/* 11) Quy trình vận hành mẫu */

-- Tạo booking mới
DECLARE @NewID INT;
EXEC hotel.usp_CreateBooking
  @GuestID = 2,
  @RoomID = 2,
  @CheckIn = '2025-11-21',
  @CheckOut = '2025-11-23',
  @Adults = 2,
  @Children = 0,
  @NightlyRate = 800000,
  @BookingID = @NewID OUTPUT;
SELECT @NewID AS BookingID;
GO

-- Ghi nhận thanh toán
INSERT INTO hotel.Payments (BookingID, Amount, Method, Note)
VALUES (@NewID, 1600000, N'CARD', N'Prepaid 2 nights');
GO

-- Check-in, sau đó check-out
UPDATE hotel.Bookings SET Status = N'CHECKED_IN' WHERE BookingID = @NewID;
GO
UPDATE hotel.Bookings SET Status = N'CHECKED_OUT' WHERE BookingID = @NewID;
GO

-- Hủy và hoàn tiền (ví dụ)
EXEC hotel.usp_CancelBooking @BookingID = @NewID, @RefundAmount = 800000;
GO