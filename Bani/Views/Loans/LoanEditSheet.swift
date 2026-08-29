import SwiftUI
import SwiftData

/// Add or edit a loan. Kind (bank / investor), lender, principal, rate, term,
/// start, and — for bank loans — the project its interest books against. Saving a
/// NEW loan generates its full payment series (`LoanStore.createLoan`); editing an
/// existing one re-syncs the pending payments to the new terms
/// (`LoanStore.syncPendingPayment`), leaving already-booked payments untouched.
struct LoanEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Project.sortOrder), SortDescriptor(\Project.createdAt, order: .reverse)])
    private var projects: [Project]

    /// `nil` → create; non-nil → edit that loan.
    let loan: Loan?

    @State private var kind: LoanKind
    @State private var name: String
    @State private var lender: String
    @State private var principalText: String
    @State private var currency: Currency
    @State private var rateText: String
    @State private var termText: String
    @State private var startDate: Date
    @State private var fixedPaymentText: String
    @State private var selectedProjectID: UUID?
    @State private var notes: String

    /// Render an optional value as editable text ("" when nil) — used to seed the
    /// numeric fields without nested optional-chaining ambiguity.
    private static func fieldText<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? ""
    }

    init(loan: Loan?) {
        self.loan = loan
        _kind = State(initialValue: loan?.kind ?? .bank)
        _name = State(initialValue: loan?.name ?? "")
        _lender = State(initialValue: loan?.lender ?? "")
        _principalText = State(initialValue: Self.fieldText(loan?.principal))
        _currency = State(initialValue: loan?.currency ?? .ron)
        _rateText = State(initialValue: Self.fieldText(loan?.annualRatePercent))
        _termText = State(initialValue: Self.fieldText(loan?.termMonths))
        _startDate = State(initialValue: loan?.startDate ?? Date())
        _fixedPaymentText = State(initialValue: Self.fieldText(loan?.fixedMonthlyPayment))
        _selectedProjectID = State(initialValue: loan?.projectID)
        _notes = State(initialValue: loan?.notes ?? "")
    }

    private func parseDecimal(_ text: String) -> Decimal? {
        Decimal(string: text.replacingOccurrences(of: ",", with: "."))
    }
    private var parsedPrincipal: Decimal? {
        guard let value = parseDecimal(principalText), value > 0 else { return nil }
        return value
    }
    private var parsedTerm: Int? { Int(termText.trimmingCharacters(in: .whitespaces)) }
    /// Every OTHER `canSave` guard: a valid principal, non-blank name/lender, and
    /// either a term or a fixed payment entered. Split out from `canSave` so the
    /// follow-up-3 footnote (`blockedOnlyByNonAmortizingPayment`) can tell "the
    /// form is genuinely incomplete" apart from "the form is complete but this
    /// fixed payment can never amortize" without duplicating the guard chain.
    private var formOtherwiseComplete: Bool {
        guard parsedPrincipal != nil else { return false }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !lender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // A schedule needs either a term or a fixed monthly payment.
        return parsedTerm != nil || parseDecimal(fixedPaymentText) != nil
    }
    /// M5: reject a fixed monthly payment that can't amortize (≤ first-period
    /// interest) — it would collapse the schedule and understate total interest.
    /// `true` (never blocks) when the form isn't complete enough yet to judge —
    /// `canSave` already gates on `formOtherwiseComplete` separately.
    private var passesAmortizationCheck: Bool {
        guard let principal = parsedPrincipal else { return true }
        return AmortizationSchedule.canAmortize(
            principal: principal,
            annualRatePercent: parseDecimal(rateText),
            fixedMonthlyPayment: parseDecimal(fixedPaymentText)
        )
    }
    private var canSave: Bool { formOtherwiseComplete && passesAmortizationCheck }
    /// Follow-up 3 (v2.2 M5 footnote): true only when the form is otherwise
    /// complete and `canAmortize` alone is what's blocking save — never shown for
    /// a plain incomplete form (empty name, missing principal, …).
    private var blockedOnlyByNonAmortizingPayment: Bool { formOtherwiseComplete && !passesAmortizationCheck }
    private var activeProjects: [ProjectSnapshot] {
        projects.filter { !$0.archived }.map(\.snapshot)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("loan.field.kind", selection: $kind) {
                        ForEach(LoanKind.allCases, id: \.self) { k in Text(k.label).tag(k) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("loan.kindPicker")

                    TextField("loan.field.name", text: $name)
                        .accessibilityIdentifier("loan.nameField")
                    TextField("loan.field.lender", text: $lender)
                        .accessibilityIdentifier("loan.lenderField")
                } header: {
                    Text("loan.section.identity")
                }
                .listRowBackground(Palette.surface)

                Section {
                    HStack {
                        TextField("0", text: $principalText)
                            .keyboardType(.decimalPad)
                            .font(Typography.amount(.title3, weight: .semibold))
                            .accessibilityIdentifier("loan.principalField")
                        Picker("Currency", selection: $currency) {
                            ForEach(Currency.allCases, id: \.self) { c in Text(c.displayCode).tag(c) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .accessibilityIdentifier("loan.currencyToggle")
                    }
                    TextField("loan.field.rate", text: $rateText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("loan.rateField")
                    TextField("loan.field.term", text: $termText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("loan.termField")
                    TextField("loan.field.fixedPayment", text: $fixedPaymentText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("loan.fixedPaymentField")
                    DatePicker("loan.field.start", selection: $startDate, displayedComponents: .date)
                        .accessibilityIdentifier("loan.startPicker")
                } header: {
                    Text("loan.section.terms")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("loan.section.terms.footer")
                        // Follow-up 3 (v2.2 M5): the ONLY reason Save is disabled is a
                        // fixed payment that can never amortize the loan.
                        if blockedOnlyByNonAmortizingPayment {
                            Text("loan.error.paymentBelowInterest")
                                .accessibilityIdentifier("loan.error.paymentBelowInterest")
                        }
                    }
                }
                .listRowBackground(Palette.surface)

                Section {
                    if kind == .bank {
                        ProjectPickerRow(projects: activeProjects, selectedID: $selectedProjectID)
                    } else {
                        // Investor interest is cost-of-capital — never a project expense.
                        Text("loan.investor.noProject")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryInk)
                    }
                    TextField("loan.field.notes", text: $notes, axis: .vertical)
                        .accessibilityIdentifier("loan.notesField")
                } header: {
                    Text("loan.section.assignment")
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle(loan == nil ? "loan.create.title" : "loan.edit.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("loan.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                        .tint(Palette.accent)
                        .accessibilityIdentifier("loan.save")
                }
            }
        }
    }

    private func save() {
        guard let principal = parsedPrincipal else { return }
        // M5: reject non-amortizing terms before mutating/persisting anything (also
        // gated by `canSave`; this guard closes the programmatic path too).
        guard (try? LoanStore.validate(
            principal: principal,
            annualRatePercent: parseDecimal(rateText),
            fixedMonthlyPayment: parseDecimal(fixedPaymentText)
        )) != nil else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLender = lender.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bank loan keeps its project; investor money is off every project rollup.
        let projectID = kind == .bank ? selectedProjectID : nil
        let rate = parseDecimal(rateText)
        let fixed = parseDecimal(fixedPaymentText)

        if let loan {
            loan.kind = kind
            loan.name = cleanName
            loan.lender = cleanLender
            loan.principal = principal
            loan.currency = currency
            loan.annualRatePercent = rate
            loan.termMonths = parsedTerm
            loan.fixedMonthlyPayment = fixed
            loan.startDate = startDate
            loan.projectID = projectID
            loan.notes = notes
            LoanStore.syncPendingPayment(for: loan, in: modelContext)
        } else {
            let created = Loan(
                name: cleanName, lender: cleanLender, kind: kind, principal: principal,
                currency: currency, annualRatePercent: rate, startDate: startDate,
                termMonths: parsedTerm, fixedMonthlyPayment: fixed, projectID: projectID,
                notes: notes
            )
            LoanStore.createLoan(created, in: modelContext)
        }
        dismiss()
    }
}
