;; HedgeBox - Automated Hedging Contract for Bitcoin Holders
;; Protects BTC holders from forex volatility through synthetic currency exposures

(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED u100)
(define-constant ERR-INVALID-AMOUNT u101)
(define-constant ERR-INVALID-RATE u102)
(define-constant ERR-INVALID-DURATION u103)
(define-constant ERR-INVALID-CURRENCY u104)
(define-constant ERR-HEDGE-NOT-FOUND u105)
(define-constant ERR-HEDGE-EXPIRED u106)
(define-constant ERR-HEDGE-NOT-EXPIRED u107)
(define-constant ERR-INSUFFICIENT-COLLATERAL u108)
(define-constant ERR-INVALID-HEDGE-ID u109)
(define-constant ERR-INVALID-DESCRIPTION u110)
(define-constant ERR-NOT-HEDGE-OWNER u111)

;; Constants for validation
(define-constant MIN-AMOUNT u1000000)
(define-constant MAX-AMOUNT u1000000000000)
(define-constant MIN-RATE u1)
(define-constant MAX-RATE u1000000)
(define-constant MIN-DURATION u100)
(define-constant MAX-DURATION u525600)
(define-constant MIN-COLLATERAL-RATIO u15000)
(define-constant MAX-DESCRIPTION-LENGTH u200)
(define-constant PLATFORM-FEE-BASIS-POINTS u50)

;; Hedge data structure
(define-map hedges
  { hedge-id: uint }
  {
    holder: principal,
    btc-amount: uint,
    target-currency: (string-ascii 10),
    hedge-rate: uint,
    collateral-posted: uint,
    created-block: uint,
    expiry-block: uint,
    description: (string-ascii 200),
    is-active: bool,
    is-settled: bool,
    settlement-price: uint
  }
)

;; Collateral tracking per holder
(define-map holder-collateral
  { holder: principal }
  {
    total-collateral: uint,
    locked-collateral: uint,
    available-collateral: uint
  }
)

;; Hedge counter
(define-data-var next-hedge-id uint u0)

;; Platform fee recipient
(define-data-var fee-recipient principal tx-sender)

;; Platform fee percentage (in basis points)
(define-data-var platform-fee-bps uint PLATFORM-FEE-BASIS-POINTS)

;; Create a new hedge
(define-public (create-hedge (btc-amount uint) (target-currency (string-ascii 10)) (hedge-rate uint) (duration-blocks uint) (collateral-amount uint) (description (string-ascii 200)))
  (let (
    (hedge-id (var-get next-hedge-id))
    (validated-btc-amount (if (and (>= btc-amount MIN-AMOUNT) (<= btc-amount MAX-AMOUNT)) (ok btc-amount) (err ERR-INVALID-AMOUNT)))
    (validated-rate (if (and (>= hedge-rate MIN-RATE) (<= hedge-rate MAX-RATE)) (ok hedge-rate) (err ERR-INVALID-RATE)))
    (validated-duration (if (and (>= duration-blocks MIN-DURATION) (<= duration-blocks MAX-DURATION)) (ok duration-blocks) (err ERR-INVALID-DURATION)))
    (validated-currency (if (> (len target-currency) u0) (ok target-currency) (err ERR-INVALID-CURRENCY)))
    (validated-description (if (<= (len description) MAX-DESCRIPTION-LENGTH) (ok description) (err ERR-INVALID-DESCRIPTION)))
    (validated-collateral (if (>= collateral-amount MIN-AMOUNT) (ok collateral-amount) (err ERR-INVALID-AMOUNT)))
    (required-collateral (/ (* btc-amount hedge-rate) u10000))
    (collateral-valid (if (>= collateral-amount required-collateral) (ok true) (err ERR-INSUFFICIENT-COLLATERAL)))
  )
    (try! validated-btc-amount)
    (try! validated-rate)
    (try! validated-duration)
    (try! validated-currency)
    (try! validated-description)
    (try! validated-collateral)
    (try! collateral-valid)

    ;; Transfer collateral from holder to contract
    (try! (stx-transfer? collateral-amount tx-sender (as-contract tx-sender)))

    ;; Update holder collateral tracking
    (let (
      (current-collateral (default-to
        { total-collateral: u0, locked-collateral: u0, available-collateral: u0 }
        (map-get? holder-collateral { holder: tx-sender })
      ))
    )
      (map-set holder-collateral
        { holder: tx-sender }
        {
          total-collateral: (+ (get total-collateral current-collateral) collateral-amount),
          locked-collateral: (+ (get locked-collateral current-collateral) collateral-amount),
          available-collateral: (get available-collateral current-collateral)
        }
      )
    )

    ;; Create hedge record
    (map-set hedges
      { hedge-id: hedge-id }
      {
        holder: tx-sender,
        btc-amount: btc-amount,
        target-currency: target-currency,
        hedge-rate: hedge-rate,
        collateral-posted: collateral-amount,
        created-block: block-height,
        expiry-block: (+ block-height duration-blocks),
        description: description,
        is-active: true,
        is-settled: false,
        settlement-price: u0
      }
    )

    ;; Increment hedge counter
    (var-set next-hedge-id (+ hedge-id u1))

    (ok hedge-id)
  )
)

;; Settle a hedge with final currency price
(define-public (settle-hedge (hedge-id uint) (settlement-price uint))
  (let (
    ;; Add validation for hedge-id to eliminate unchecked data warning
    (validated-hedge-id (if (< hedge-id (var-get next-hedge-id)) (ok hedge-id) (err ERR-INVALID-HEDGE-ID)))
    (hedge (unwrap! (map-get? hedges { hedge-id: hedge-id }) (err ERR-HEDGE-NOT-FOUND)))
    (validated-price (if (and (>= settlement-price MIN-RATE) (<= settlement-price MAX-RATE)) (ok settlement-price) (err ERR-INVALID-RATE)))
  )
    (try! validated-hedge-id)
    (try! validated-price)

    ;; Verify hedge exists and is active
    (asserts! (get is-active hedge) (err ERR-HEDGE-NOT-FOUND))
    (asserts! (not (get is-settled hedge)) (err ERR-HEDGE-EXPIRED))
    (asserts! (>= block-height (get expiry-block hedge)) (err ERR-HEDGE-NOT-EXPIRED))
    (asserts! (is-eq tx-sender (get holder hedge)) (err ERR-NOT-HEDGE-OWNER))

    ;; Calculate payout
    (let (
      (original-rate (get hedge-rate hedge))
      (btc-amount (get btc-amount hedge))
      (collateral-posted (get collateral-posted hedge))
      (rate-difference (if (> settlement-price original-rate)
        (- settlement-price original-rate)
        u0
      ))
      (payout-gain (* btc-amount rate-difference))
      (fee-amount (/ (* payout-gain PLATFORM-FEE-BASIS-POINTS) u10000))
      (net-payout (if (> payout-gain fee-amount) (- payout-gain fee-amount) u0))
      (total-return (+ collateral-posted net-payout))
    )
      ;; Return collateral and gains to holder
      (try! (as-contract (stx-transfer? total-return (as-contract tx-sender) (get holder hedge))))

      ;; Transfer platform fee
      (try! (as-contract (stx-transfer? fee-amount (as-contract tx-sender) (var-get fee-recipient))))

      ;; Update hedge status
      (map-set hedges
        { hedge-id: hedge-id }
        (merge hedge {
          is-active: false,
          is-settled: true,
          settlement-price: settlement-price
        })
      )

      ;; Update collateral tracking
      (let (
        (current-collateral (unwrap! (map-get? holder-collateral { holder: (get holder hedge) }) (err ERR-UNAUTHORIZED)))
      )
        (map-set holder-collateral
          { holder: (get holder hedge) }
          {
            total-collateral: (get total-collateral current-collateral),
            locked-collateral: (- (get locked-collateral current-collateral) collateral-posted),
            available-collateral: (+ (get available-collateral current-collateral) collateral-posted)
          }
        )
      )

      (ok true)
    )
  )
)

;; Cancel an active hedge and return collateral
(define-public (cancel-hedge (hedge-id uint))
  (let (
    ;; Add validation for hedge-id to eliminate unchecked data warning
    (validated-hedge-id (if (< hedge-id (var-get next-hedge-id)) (ok hedge-id) (err ERR-INVALID-HEDGE-ID)))
    (hedge (unwrap! (map-get? hedges { hedge-id: hedge-id }) (err ERR-HEDGE-NOT-FOUND)))
  )
    (try! validated-hedge-id)

    ;; Verify authorization and hedge status
    (asserts! (is-eq tx-sender (get holder hedge)) (err ERR-NOT-HEDGE-OWNER))
    (asserts! (get is-active hedge) (err ERR-HEDGE-NOT-FOUND))
    (asserts! (not (get is-settled hedge)) (err ERR-HEDGE-EXPIRED))

    ;; Return collateral to holder
    (try! (as-contract (stx-transfer? (get collateral-posted hedge) (as-contract tx-sender) (get holder hedge))))

    ;; Update hedge status
    (map-set hedges
      { hedge-id: hedge-id }
      (merge hedge {
        is-active: false,
        is-settled: true
      })
    )

    ;; Update collateral tracking
    (let (
      (current-collateral (unwrap! (map-get? holder-collateral { holder: (get holder hedge) }) (err ERR-UNAUTHORIZED)))
    )
      (map-set holder-collateral
        { holder: (get holder hedge) }
        {
          total-collateral: (- (get total-collateral current-collateral) (get collateral-posted hedge)),
          locked-collateral: (- (get locked-collateral current-collateral) (get collateral-posted hedge)),
          available-collateral: (get available-collateral current-collateral)
        }
      )
    )

    (ok true)
  )
)

;; Admin: Update platform fee
(define-public (set-platform-fee (new-fee-bps uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) (err ERR-UNAUTHORIZED))
    (asserts! (<= new-fee-bps u1000) (err ERR-INVALID-AMOUNT))
    (var-set platform-fee-bps new-fee-bps)
    (ok true)
  )
)

;; Admin: Update fee recipient
(define-public (set-fee-recipient (new-recipient principal))
  (let (
    ;; Add validation for principal parameter to eliminate unchecked data warning
    (validated-recipient (if (not (is-eq new-recipient (as-contract tx-sender))) (ok new-recipient) (err ERR-UNAUTHORIZED)))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) (err ERR-UNAUTHORIZED))
    (try! validated-recipient)
    (var-set fee-recipient new-recipient)
    (ok true)
  )
)

;; Read-only: Get hedge details
(define-read-only (get-hedge (hedge-id uint))
  (map-get? hedges { hedge-id: hedge-id })
)

;; Read-only: Get holder collateral information
(define-read-only (get-holder-collateral (holder principal))
  (map-get? holder-collateral { holder: holder })
)

;; Read-only: Get next hedge ID
(define-read-only (get-next-hedge-id)
  (var-get next-hedge-id)
)

;; Read-only: Get platform fee
(define-read-only (get-platform-fee)
  (var-get platform-fee-bps)
)

;; Read-only: Get fee recipient
(define-read-only (get-fee-recipient)
  (var-get fee-recipient)
)

;; Read-only: Calculate hedge payout
(define-read-only (calculate-hedge-payout (hedge-id uint) (settlement-price uint))
  (let (
    (hedge (unwrap! (map-get? hedges { hedge-id: hedge-id }) (err ERR-HEDGE-NOT-FOUND)))
    (original-rate (get hedge-rate hedge))
    (btc-amount (get btc-amount hedge))
    (rate-difference (if (> settlement-price original-rate)
      (- settlement-price original-rate)
      u0
    ))
    (payout-gain (* btc-amount rate-difference))
    (fee-amount (/ (* payout-gain (var-get platform-fee-bps)) u10000))
  )
    (ok {
      gross-payout: payout-gain,
      platform-fee: fee-amount,
      net-payout: (if (> payout-gain fee-amount) (- payout-gain fee-amount) u0)
    })
  )
)

;; Read-only: Check if hedge is active
(define-read-only (is-hedge-active (hedge-id uint))
  (let (
    (hedge (unwrap! (map-get? hedges { hedge-id: hedge-id }) (err ERR-HEDGE-NOT-FOUND)))
  )
    (ok (and (get is-active hedge) (< block-height (get expiry-block hedge))))
  )
)
