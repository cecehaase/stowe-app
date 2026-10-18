import Foundation

/// Rough paycheck-withholding estimate for a pre-tax yearly salary.
/// Intentionally simplified (no dependents, credits, HSA, local taxes or itemizing) — not tax advice.
enum MaritalStatus: String, Codable, CaseIterable, Identifiable {
    case single, married
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Every field is optional; anything the user skips falls back to a general assumption.
struct TaxInputs: Codable, Hashable {
    var maritalStatus: MaritalStatus?
    var contribution401kPercent: Double?
    var stateCode: String?
}

struct TaxEstimate {
    static let paychecksPerYear = 26.0 // assumes biweekly pay

    let annualGross: Double
    let annual401k: Double
    let annualTaxes: Double
    /// True when one or more inputs were skipped and defaults were used.
    let isGeneralEstimate: Bool

    var annualNet: Double { annualGross - annual401k - annualTaxes }
    var perPaycheckTaxes: Double { annualTaxes / Self.paychecksPerYear }
    var perPaycheckNet: Double { annualNet / Self.paychecksPerYear }
    var monthlyNet: Double { annualNet / 12 }
    var effectiveRate: Double { annualGross > 0 ? annualTaxes / annualGross : 0 }
}

struct USState: Identifiable, Hashable {
    let code: String
    let name: String
    /// Approximate effective state income-tax rate on taxable wages for a middle income.
    let rate: Double
    var id: String { code }
}

enum TaxEstimator {
    // 2026 federal figures.
    private static let standardDeduction: [MaritalStatus: Double] = [.single: 16_100, .married: 32_200]
    private static let brackets: [MaritalStatus: [(upTo: Double, rate: Double)]] = [
        .single: [(12_400, 0.10), (50_400, 0.12), (105_700, 0.22), (201_775, 0.24),
                  (256_225, 0.32), (640_600, 0.35), (.infinity, 0.37)],
        .married: [(24_800, 0.10), (100_800, 0.12), (211_400, 0.22), (403_550, 0.24),
                   (512_450, 0.32), (768_700, 0.35), (.infinity, 0.37)],
    ]
    private static let socialSecurityWageBase = 184_500.0
    private static let additionalMedicareThreshold: [MaritalStatus: Double] = [.single: 200_000, .married: 250_000]
    /// Used when the user doesn't pick a state.
    private static let nationalAverageStateRate = 0.035

    static func estimate(annualGross gross: Double, inputs: TaxInputs) -> TaxEstimate {
        let status = inputs.maritalStatus ?? .single
        let contribution = gross * min(max(inputs.contribution401kPercent ?? 0, 0), 100) / 100

        // Traditional 401k lowers income tax but not FICA.
        let wages = max(gross - contribution, 0)
        let taxable = max(wages - (standardDeduction[status] ?? 0), 0)
        let federal = bracketTax(on: taxable, brackets: brackets[status] ?? [])

        let medicareExtra = max(gross - (additionalMedicareThreshold[status] ?? .infinity), 0) * 0.009
        let fica = min(gross, socialSecurityWageBase) * 0.062 + gross * 0.0145 + medicareExtra

        let stateRate = inputs.stateCode.flatMap(state(for:))?.rate ?? nationalAverageStateRate
        let stateTax = wages * stateRate

        let isGeneral = inputs.maritalStatus == nil || inputs.contribution401kPercent == nil || inputs.stateCode == nil
        return TaxEstimate(annualGross: gross, annual401k: contribution,
                           annualTaxes: federal + fica + stateTax, isGeneralEstimate: isGeneral)
    }

    static func state(for code: String) -> USState? { states.first { $0.code == code } }

    private static func bracketTax(on income: Double, brackets: [(upTo: Double, rate: Double)]) -> Double {
        var tax = 0.0, lower = 0.0
        for b in brackets where income > lower {
            tax += (min(income, b.upTo) - lower) * b.rate
            lower = b.upTo
        }
        return tax
    }

    static let states: [USState] = [
        .init(code: "AL", name: "Alabama", rate: 0.040), .init(code: "AK", name: "Alaska", rate: 0),
        .init(code: "AZ", name: "Arizona", rate: 0.025), .init(code: "AR", name: "Arkansas", rate: 0.035),
        .init(code: "CA", name: "California", rate: 0.050), .init(code: "CO", name: "Colorado", rate: 0.044),
        .init(code: "CT", name: "Connecticut", rate: 0.045), .init(code: "DE", name: "Delaware", rate: 0.045),
        .init(code: "DC", name: "District of Columbia", rate: 0.055), .init(code: "FL", name: "Florida", rate: 0),
        .init(code: "GA", name: "Georgia", rate: 0.050), .init(code: "HI", name: "Hawaii", rate: 0.065),
        .init(code: "ID", name: "Idaho", rate: 0.053), .init(code: "IL", name: "Illinois", rate: 0.0495),
        .init(code: "IN", name: "Indiana", rate: 0.042), .init(code: "IA", name: "Iowa", rate: 0.038),
        .init(code: "KS", name: "Kansas", rate: 0.045), .init(code: "KY", name: "Kentucky", rate: 0.040),
        .init(code: "LA", name: "Louisiana", rate: 0.030), .init(code: "ME", name: "Maine", rate: 0.050),
        .init(code: "MD", name: "Maryland", rate: 0.055), .init(code: "MA", name: "Massachusetts", rate: 0.050),
        .init(code: "MI", name: "Michigan", rate: 0.0425), .init(code: "MN", name: "Minnesota", rate: 0.055),
        .init(code: "MS", name: "Mississippi", rate: 0.044), .init(code: "MO", name: "Missouri", rate: 0.040),
        .init(code: "MT", name: "Montana", rate: 0.047), .init(code: "NE", name: "Nebraska", rate: 0.045),
        .init(code: "NV", name: "Nevada", rate: 0), .init(code: "NH", name: "New Hampshire", rate: 0),
        .init(code: "NJ", name: "New Jersey", rate: 0.040), .init(code: "NM", name: "New Mexico", rate: 0.040),
        .init(code: "NY", name: "New York", rate: 0.055), .init(code: "NC", name: "North Carolina", rate: 0.0425),
        .init(code: "ND", name: "North Dakota", rate: 0.015), .init(code: "OH", name: "Ohio", rate: 0.030),
        .init(code: "OK", name: "Oklahoma", rate: 0.040), .init(code: "OR", name: "Oregon", rate: 0.075),
        .init(code: "PA", name: "Pennsylvania", rate: 0.0307), .init(code: "RI", name: "Rhode Island", rate: 0.045),
        .init(code: "SC", name: "South Carolina", rate: 0.045), .init(code: "SD", name: "South Dakota", rate: 0),
        .init(code: "TN", name: "Tennessee", rate: 0), .init(code: "TX", name: "Texas", rate: 0),
        .init(code: "UT", name: "Utah", rate: 0.0455), .init(code: "VT", name: "Vermont", rate: 0.050),
        .init(code: "VA", name: "Virginia", rate: 0.048), .init(code: "WA", name: "Washington", rate: 0),
        .init(code: "WV", name: "West Virginia", rate: 0.045), .init(code: "WI", name: "Wisconsin", rate: 0.048),
        .init(code: "WY", name: "Wyoming", rate: 0),
    ]
}
