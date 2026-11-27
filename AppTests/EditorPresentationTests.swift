import Foundation
import OboloCore
import Testing

@MainActor
@Suite("Editor presentation")
struct EditorPresentationTests {
    @Test("Presenting Add reuses the draft when the prefill matches")
    func addRequestsKeepOrReplaceDraft() throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()

        model.presentAdd()
        let blank = try #require(model.activeSheet)
        model.presentAdd(prefill: .init())
        #expect(model.activeSheet?.id == blank.id)

        let music = SubscriptionFormPrefill(name: "Music")
        model.presentAdd(prefill: music)
        let prefilled = try #require(model.activeSheet)
        #expect(prefilled.id != blank.id)
        #expect(prefilled.content == .add(music))
        model.presentAdd(prefill: music)
        #expect(model.activeSheet?.id == prefilled.id)

        let video = SubscriptionFormPrefill(name: "Video")
        model.presentAdd(prefill: video)
        #expect(model.activeSheet?.id != prefilled.id)
        #expect(model.activeSheet?.content == .add(video))
        model.dismissSheet(prefilled.id)
        #expect(model.activeSheet?.content == .add(video))

        model.presentAdd()
        #expect(model.activeSheet?.id != blank.id)
        #expect(model.activeSheet?.content == .add(.init()))
        #expect(model.document == fixture.document)
    }

    @Test("External Add requests wait behind an open form and keep their order")
    func externalAddsWaitInOrder() throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let router = OboloIntentRouter()
        let music = SubscriptionFormPrefill(name: "Music")
        let video = SubscriptionFormPrefill(name: "Video")

        model.presentAdd()
        let original = try #require(model.activeSheet)
        router.request(.addSubscription(music))
        router.request(.addSubscription(video))
        router.request(.upcoming)
        #expect(router.takePendingRoute(activeSheet: model.activeSheet) == nil)
        #expect(model.activeSheet?.id == original.id)

        model.dismissSheet(original.id)
        #expect(router.takePendingRoute(activeSheet: model.activeSheet) == .addSubscription(music))
        model.presentAdd(prefill: music)
        let first = try #require(model.activeSheet)
        #expect(router.takePendingRoute(activeSheet: model.activeSheet) == nil)

        model.dismissSheet(first.id)
        #expect(router.takePendingRoute(activeSheet: model.activeSheet) == .addSubscription(video))
        #expect(router.takePendingRoute(activeSheet: model.activeSheet) == .upcoming)
        #expect(router.takePendingRoute(activeSheet: model.activeSheet) == nil)
    }

    @Test("An identical external Add can reuse the current draft")
    func externalAddReusesMatchingDraft() throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let router = OboloIntentRouter()
        let prefill = SubscriptionFormPrefill(name: "Music")
        model.presentAdd(prefill: prefill)
        let sheet = try #require(model.activeSheet)

        router.request(.addSubscription(prefill))
        #expect(router.takePendingRoute(activeSheet: model.activeSheet) == .addSubscription(prefill))
        model.presentAdd(prefill: prefill)
        #expect(model.activeSheet?.id == sheet.id)
        #expect(router.takePendingRoute(activeSheet: model.activeSheet) == nil)
    }

    @Test("Edit starts fresh when the entry point changes the opening focus")
    func editFocusBelongsToTheRequest() throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let subscription = fixture.subscription(name: "Edited plan")
        var document = fixture.document
        document.subscriptions = [subscription]
        let model = fixture.makeModel(document: document)

        model.presentEdit(subscription.id, focus: .newPriceChange)
        let priceChange = try #require(model.activeSheet)
        #expect(priceChange.content == .edit(subscription.id, focus: .newPriceChange))
        model.presentEdit(subscription.id, focus: .newPriceChange)
        #expect(model.activeSheet?.id == priceChange.id)

        model.presentEdit(subscription.id, focus: .firstPayment)
        let firstPayment = try #require(model.activeSheet)
        #expect(firstPayment.id != priceChange.id)
        #expect(firstPayment.content == .edit(subscription.id, focus: .firstPayment))

        model.presentEdit(subscription.id)
        #expect(model.activeSheet?.id != firstPayment.id)
        #expect(model.activeSheet?.content == .edit(subscription.id, focus: .name))
        #expect(model.document == document)
    }

    @Test("Plain Edit replaces a reactivation request on the same row")
    func editReplacesReactivation() throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        var subscription = fixture.subscription(name: "Cancelled plan")
        subscription.status = .cancelled
        subscription.anchorDate = nil
        subscription.billingStoppedOn = BillingDay(isoDate: "2026-08-22")!
        subscription.endsOn = BillingDay(isoDate: "2026-08-29")!
        var document = fixture.document
        document.subscriptions = [subscription]
        let model = fixture.makeModel(document: document)

        model.setStatus(.active, for: subscription.id)
        let reactivation = try #require(model.activeSheet)
        var expected = subscription
        expected.status = .active
        expected.anchorDate = BillingDay(fixture.now, calendar: fixture.calendar)
        expected.billingStoppedOn = nil
        expected.endsOn = nil
        #expect(reactivation.content == .reactivate(expected))
        #expect(model.subscription(subscription.id) == subscription)

        model.presentEdit(subscription.id)
        #expect(model.activeSheet?.id != reactivation.id)
        #expect(model.activeSheet?.content == .edit(subscription.id, focus: .name))
        #expect(model.subscription(subscription.id) == subscription)
    }

    @Test("Import replaces the open editor and the next New opens with a blank draft")
    func importReplacesEditor() throws {
        let fixture = TestFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.presentAdd(prefill: .init(name: "Video"))
        let editor = try #require(model.activeSheet)

        let preview = try model.previewImport(data: Data("Name,Price\nImported plan,8".utf8))
        model.presentImportPreview(preview)
        let imported = try #require(model.activeSheet)
        #expect(imported.id != editor.id)
        #expect(imported.content == .importPreview(preview))
        model.dismissSheet(editor.id)
        #expect(model.activeSheet?.id == imported.id)

        model.dismissSheet(imported.id)
        model.presentAdd()
        #expect(model.activeSheet?.content == .add(.init()))
        #expect(model.document == fixture.document)
    }
}
