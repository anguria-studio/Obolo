import SwiftUI
import OboloCore

/// Preferences → Currencies: the base currency, the automatic rates, and the rate table.
///
/// The rates belong to the *document*, not the settings — which is why a backup carries
/// the user's hand-entered rates, and why every change here goes through `AppModel`
/// rather than being held locally and saved on close.
struct CurrenciesPane: View {

    let model: AppModel

    @State private var isAddingRate = false
    @State private var newRateCode = ""
    @State private var newRateValue: Decimal = 1

    private enum Metrics {
        static let codeWidth: CGFloat = 46
        static let rateWidth: CGFloat = 90
    }

    private var base: String { model.document.settings.baseCurrency }
    private var rateCodes: [String] { model.document.rates.rates.keys.sorted() }

    var body: some View {
        PrefPage(tab: .currencies) {
            money
            ratesSection
            rateTable
        }
    }

    // MARK: - Money

    private var money: some View {
        @Bindable var settings = model.settings
        return PrefSection("Base currency") {
            PrefRow("Base currency", "Obolo converts each amount to this currency before it adds the totals.") {
                PrefMenu(base, accessibilityLabel: "Base currency") {
                    Picker("Base currency", selection: $settings.baseCurrency) {
                        ForEach(preferredCurrencies, id: \.self) { code in
                            Text(currencyLabel(code)).tag(code)
                        }
                        Divider()
                        ForEach(otherCurrencies, id: \.self) { code in
                            Text(currencyLabel(code)).tag(code)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        } footer: {
            PrefFootnote("When you change the base currency, Obolo gets the automatic rates again. It keeps the rates that you entered by hand.")
        }
    }

    // MARK: - Currency lists

    /// The base, the codes with a rate, and the codes in use — the answer is almost
    /// always one of these.
    private var preferredCurrencies: [String] {
        model.currencyChoices
    }

    /// Everything else ISO 4217 knows about, minus the ones already offered.
    private var otherCurrencies: [String] {
        let preferred = Set(preferredCurrencies)
        return Locale.Currency.isoCurrencies
            .map { $0.identifier.uppercased() }
            .filter { !preferred.contains($0) }
            .sorted()
    }

    /// "EUR — Euro", falling back to the bare code for the ones the locale has no name
    /// for.
    private func currencyLabel(_ code: String) -> String {
        guard let name = Locale.current.localizedString(forCurrencyCode: code), name != code else {
            return code
        }
        return "\(code) (\(name))"
    }

    // MARK: - Rates

    /// The switch and, while it is on, when the rates last landed.
    private var ratesSection: some View {
        PrefSection("Currency rates") {
            PrefToggleRow(
                "Update rates automatically",
                "Obolo gets ECB reference rates from frankfurter.dev once a day. It sends only the currency codes.",
                isOn: model.settings.binding(\.autoUpdateRates)
            )

            if model.document.settings.autoUpdateRates {
                refreshStatusRow
            }
        }
    }

    /// The table itself, in a card of its own under the switch: the base, one row per
    /// rate, and the row that adds one.
    private var rateTable: some View {
        PrefSection {
            baseRow
            ForEach(rateCodes, id: \.self) { code in
                rateRow(code)
            }
            if isAddingRate {
                addRateRow
            } else {
                PrefButtonRow("Add rate", help: "Add a currency rate") {
                    newRateCode = ""
                    newRateValue = 1
                    isAddingRate = true
                }
            }
        } footer: {
            PrefFootnote("An update does not change a rate that you entered by hand. If a currency has no rate, Obolo keeps it out of the totals and adds a footnote. Obolo does not count it at 1:1.")
        }
    }

    /// When the rates last landed, and the way to ask for them now.
    ///
    /// The one place a failed refresh is visible. It says what is being used instead,
    /// because "failed" without that reads as "the totals are broken" when in fact they
    /// are merely a few days old.
    private var refreshStatusRow: some View {
        let status = refreshStatus
        return HStack(alignment: .center, spacing: 16) {
            PrefRowLabel(title: status.title, description: status.detail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(refreshStatusHelp)

            HStack(spacing: 10) {
                if model.isRefreshingRates {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Button("Refresh now") {
                    Task { await model.refreshRates(force: true) }
                }
                .prefButton()
                .disabled(model.isRefreshingRates)
            }
        }
        .prefRowPadding()
    }

    /// Two facts, in this order: when Obolo last asked, and which day's fixing it is
    /// using. The first is the row's title, the second the line under it.
    ///
    /// They are not the same day and the difference is what confuses people. The ECB
    /// publishes on working days only, so all weekend the newest quote is Friday's. A
    /// line that says "Updated 21 Aug" reads as "this app has not looked since Friday",
    /// which is wrong twice over: it looked this morning, and Friday's number *is* the
    /// current one. So the check leads, in the words a person would use, and the quote
    /// day follows with the reason it is not today's.
    private var refreshStatus: (title: String, detail: String?) {
        switch model.rateRefreshState {
        case .refreshing:
            return ("Checking", nil)
        case .failed:
            guard let asOf = model.ratesAsOf else { return ("Last check failed.", nil) }
            return ("Last check failed.", "Using rates from \(shortDate(asOf)).")
        case .idle, .updated:
            guard let asOf = model.ratesAsOf else { return ("Not checked yet.", nil) }
            let day = DateFormatting.full(asOf, calendar: model.calendar)
            // A document from before checks were recorded has a quote day and nothing
            // to say about the last check. Better to say one true thing than to guess.
            guard let checkedAt = model.ratesLastCheckedAt else {
                return ("Using rates from \(day)", "The latest ECB fixing.")
            }
            return ("Checked \(checkedTense(checkedAt))", "Using rates from \(day), the latest ECB fixing.")
        }
    }

    /// "today 9:12" · "yesterday" · "2 days ago" · "14 Aug". The clock time appears only
    /// on the day itself, where the minutes are what say the app is awake; after that
    /// the hour is noise and the day is the answer.
    private func checkedTense(_ date: Date) -> String {
        let phrase = DateFormatting.renewal(date, today: model.today, calendar: model.calendar)
        guard model.calendar.isDate(date, inSameDayAs: model.today) else { return phrase }
        let time = date.formatted(
            Date.FormatStyle(calendar: model.calendar, timeZone: model.calendar.timeZone)
                .hour().minute()
        )
        return "\(phrase) \(time)"
    }

    /// The reason itself, kept to the tooltip: "no connection" is worth having when the
    /// line is worth reading twice, and worth nothing in the line itself.
    private var refreshStatusHelp: String {
        if case .failed(let message) = model.rateRefreshState { return message }
        return "The European Central Bank publishes these reference rates on each working day."
    }

    private func shortDate(_ date: Date) -> String {
        DateFormatting.absolute(date, today: model.today, calendar: model.calendar)
    }

    /// The base currency is not in the table — it is what the table converts *to* — but
    /// a rates list that does not mention it reads as a list with a missing row.
    private var baseRow: some View {
        HStack(spacing: 12) {
            codeLabel(base)

            Text("base currency")
                .font(DSFonts.font(DSFonts.sansRegular, size: 12))
                .foregroundStyle(DS.Palette.inkMuted)

            Spacer(minLength: 8)

            Text("1")
                .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                .monospacedDigit()
                .foregroundStyle(DS.Palette.inkMuted)
                .padding(.trailing, 6)
                .frame(width: Metrics.rateWidth, alignment: .trailing)
        }
        .prefRowPadding()
    }

    private func codeLabel(_ code: String) -> some View {
        Text(code)
            .font(DSFonts.font(DSFonts.monoRegular, size: 12))
            .tracking(0.5)
            .foregroundStyle(DS.Palette.ink)
            .frame(width: Metrics.codeWidth, alignment: .leading)
    }

    private func rateRow(_ code: String) -> some View {
        let isManual = model.document.rates.source(for: code) != .automatic
        return HStack(spacing: 12) {
            codeLabel(code)

            // "ECB · updated 21 Aug": where the number came from, then how old it is.
            // Both matter and neither is worth a column of its own.
            Text(provenanceText(code))
                .font(DSFonts.font(DSFonts.sansRegular, size: 12))
                .foregroundStyle(DS.Palette.inkMuted)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            TextField(
                "Rate",
                value: rateBinding(code),
                format: .number.precision(.fractionLength(0...6))
            )
            .textFieldStyle(.roundedBorder)
            .font(DSFonts.font(DSFonts.monoRegular, size: 12))
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: Metrics.rateWidth)
            .accessibilityLabel("\(code) to \(base)")

            HStack(spacing: 2) {
                // Only for a rate the user has claimed, and only while there is something
                // automatic to go back to.
                if isManual && model.document.settings.autoUpdateRates {
                    Button { model.useAutomaticRate(for: code) } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(RowIconButtonStyle())
                    .dsFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help("Use the automatic ECB rate")
                    .accessibilityLabel("Use the automatic rate for \(code)")
                }

                Button { removeRate(code) } label: { Image(systemName: "trash") }
                    .buttonStyle(RowIconButtonStyle(isDestructive: true))
                    .dsFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help("Remove \(code)")
                    .accessibilityLabel("Remove \(code)")
            }
        }
        .prefRowPadding()
        .contentShape(Rectangle())
        .contextMenu {
            if isManual && model.document.settings.autoUpdateRates {
                Button("Use automatic") { model.useAutomaticRate(for: code) }
            }
            Button("Remove \(code)", role: .destructive) { removeRate(code) }
        }
    }

    private var addRateRow: some View {
        HStack(spacing: 8) {
            TextField("USD", text: $newRateCode)
                .textFieldStyle(.roundedBorder)
                .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                .frame(width: 58)
                .accessibilityLabel("New currency code")
                .onSubmit { commitNewRate() }

            Text("=")
                .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                .foregroundStyle(DS.Palette.inkMuted)

            TextField("Rate", value: $newRateValue, format: .number.precision(.fractionLength(0...6)))
                .textFieldStyle(.roundedBorder)
                .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: Metrics.rateWidth)
                .accessibilityLabel("Rate to \(base)")

            Text(base)
                .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                .tracking(0.5)
                .foregroundStyle(DS.Palette.inkMuted)

            Spacer(minLength: 8)

            Button("Cancel") { isAddingRate = false }
                .prefButton()
            Button("Add") { commitNewRate() }
                .prefButton()
                .disabled(!isNewRateValid)
        }
        .prefRowPadding()
    }

    // MARK: - Rate edits

    /// "ECB · updated 21 Aug" or "manual · updated 3 Jan".
    private func provenanceText(_ code: String) -> String {
        guard let rate = model.document.rates.rates[code] else { return "" }
        let source = rate.source == .automatic ? "ECB" : "manual"
        return "\(source) · updated \(shortDate(rate.updatedAt))"
    }

    private func rateBinding(_ code: String) -> Binding<Decimal> {
        Binding(
            get: { model.document.rates.rates[code]?.value ?? 0 },
            set: { newValue in
                guard newValue > 0 else { return }
                var rates = model.document.rates
                rates.setRate(newValue, for: code, updatedAt: model.today)
                model.updateRates(rates)
            }
        )
    }

    private func removeRate(_ code: String) {
        var rates = model.document.rates
        rates.removeRate(for: code)
        model.updateRates(rates)
    }

    private var normalizedNewCode: String {
        Subscription.normalizedCurrency(newRateCode)
    }

    private var isNewRateValid: Bool {
        normalizedNewCode.count == 3
            && normalizedNewCode != base
            && model.document.rates.rates[normalizedNewCode] == nil
            && newRateValue > 0
    }

    private func commitNewRate() {
        guard isNewRateValid else { return }
        var rates = model.document.rates
        rates.setRate(newRateValue, for: normalizedNewCode, updatedAt: model.today)
        model.updateRates(rates)
        isAddingRate = false
    }
}

// MARK: - Preview

#Preview("Currencies") {
    CurrenciesPane(model: .handoffPreview())
        .frame(width: PrefMetrics.width, height: 520)
}
