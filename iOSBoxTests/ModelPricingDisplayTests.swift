import XCTest
@testable import iOSBox

final class ModelPricingDisplayTests: XCTestCase {
    func testOnlyCompleteValidPricesAreDisplayed() throws {
        var model = ModelSpec(id: "example")
        XCTAssertNil(ModelPricingDisplay.configuredRates(for: model))
        model.inputPricePerMillion = 0
        model.priceCurrency = "USD"
        XCTAssertNil(ModelPricingDisplay.configuredRates(for: model))
        model.outputPricePerMillion = 0.0000001
        let rates = try XCTUnwrap(ModelPricingDisplay.configuredRates(for: model))
        XCTAssertEqual(rates.currency, "USD")
        XCTAssertEqual(rates.input, 0)
        XCTAssertEqual(rates.output, 0.0000001)
        XCTAssertNotEqual(rates.output.formatted(.number.precision(.significantDigits(1...6))), "0")
        model.outputPricePerMillion = .nan
        XCTAssertNil(ModelPricingDisplay.configuredRates(for: model))
        model.outputPricePerMillion = -1
        XCTAssertNil(ModelPricingDisplay.configuredRates(for: model))
        model.outputPricePerMillion = 1
        model.priceCurrency = "UNKNOWN"
        XCTAssertNil(ModelPricingDisplay.configuredRates(for: model))
    }

    func testTinyNonzeroRatesAndTotalsRemainDistinguishableFromZero() {
        XCTAssertNotEqual(ModelPricingDisplay.rateText(0.0000001), ModelPricingDisplay.rateText(0))
        XCTAssertTrue(RequestLedger.costText(0.0000001, currency: "USD").contains("<"))
        XCTAssertNotEqual(RequestLedger.costText(0.0000001, currency: "USD"), RequestLedger.costText(0, currency: "USD"))
        XCTAssertFalse(RequestLedger.costText(0.000001, currency: "USD").contains("<"))
    }
}
