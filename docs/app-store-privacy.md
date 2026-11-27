# Mac App Store privacy answers

Use this guide for the build archived from [project-store.yml](../project-store.yml). The public [privacy policy](privacy.md) also covers the direct-download edition.

## Data collection

Apple's label covers data available to the developer or its third-party partners beyond the time needed to handle the request. Apple excludes data it collects for its own services. On-device processing is outside the label. Optional features can still require disclosure. [Apple's App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)

| Store build feature | App Store Connect treatment |
| --- | --- |
| Local library, backups, reminders and file import or export | Leave these out of Data Types. Obolo processes them on the Mac or writes files where the user directs it. |
| CloudKit sync | Leave the private iCloud records out of Data Types. The app accesses the records in the signed-in user's private database. Anguria Studio receives no copy and has no access to that database. The CloudKit account record name stays in local sync state. [Apple's private CloudKit database documentation](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase) |
| Calendar events | Leave these out of Data Types. With permission, Obolo writes events through macOS to the chosen calendar. Events contain the subscription name, amount and currency, dates and recurrence, notes and optional alerts. The provider and people who share that calendar may receive them, even with Obolo’s iCloud sync off. Anguria Studio receives no copy. |
| Frankfurter rates | Leave these out of Data Types. Requests include base and target currency codes. Frankfurter says it retains no request URLs or IP address logs, and its Cloudflare setup provides aggregate traffic statistics. [Frankfurter's privacy FAQ](https://frankfurter.dev/#faq) |
| Website icons and Google fallback | Resolve the scope and retention questions below before selecting the collection answer. |
| Updates, analytics and advertising | The Store edition uses Apple's update system. It includes no Sparkle updater, telemetry, advertising code or tracking SDK. |

## Logo requests

[LogoFetcher](../App/Services/LogoFetcher.swift) makes cookie-free requests to the subscription domain and sites that serve the icon. The app can follow redirects. Existing and newly synced logos may trigger dark-icon requests. Both paths use macOS networking directly. Anguria Studio receives no copy.

[Subscription.effectiveDomain](../Core/Sources/OboloCore/Model/Subscription.swift) falls back to the management link when the Website field is empty. The Store candidate derives the domain from the link's host. In the published 1.0.0 direct download, delimiters in the path, query or fragment can make Obolo look up a different domain. Previously saved Website fields may already contain a domain that version 1.0.0 derived from a URL. Use synthetic URLs when testing either version.

The [Google fallback](../Core/Sources/OboloCore/Logo/LogoCandidates.swift) is on by default. It sends the normalized domain and requested size to Google's favicon endpoint. Google and direct icon hosts can see the request and the usual connection metadata, including its IP address. Google's general privacy policy describes retention and use at a service-wide level. It leaves the specific favicon endpoint's retention, identity linkage and use unconfirmed. [Google's privacy policy](https://policies.google.com/privacy)

The open question for this build is whether a logo recipient collects data for the purposes of Apple’s label. Obolo chooses the Google endpoint itself. The subscription website comes from the user, and that site can choose the icon host. Assess those relationships separately. If partner status is unclear, ask App Review about this integration. For an in-scope provider, confirm what it retains and how it uses those records.

If all logo recipients are outside the label or handle requests only in real time, select **No, we do not collect data from this app**.

If an in-scope recipient keeps readable data beyond the request, select **Yes, we collect data from this app**. Consider **Other User Content** for a retained user-entered domain. If the recipient uses it as a record of the user’s subscriptions or purchases, also assess **Purchase History**. Apple’s categories depend on what the recipient actually keeps and uses.

Select **App Functionality** for icon retrieval and add any other established uses. Answer the linked-to-user and tracking questions based on the recipient's practices. A stored IP address can require an additional data type depending on its use. [Apple's App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)

If there is data collection, review the release build against Apple's requirements for consent, withdrawal and third-party protection before publication. Google fallback starts on and the app can fetch logos on save or import. [App Review Guidelines §5.1.1](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage)

## Listing and release check

The canonical policy URL is [https://github.com/anguria-studio/Obolo/blob/main/docs/privacy.md](https://github.com/anguria-studio/Obolo/blob/main/docs/privacy.md).

1. Once the policy is on `main`, open the policy URL signed out of GitHub.
2. Open **Help → Privacy Policy** in the release build. Verify that it opens the same page.
3. In App Store Connect, open **Obolo → App Privacy**. Set the macOS **Privacy Policy URL** and save.
4. Complete **Data Collection** based on the verified answers above. Review the **Product Page Preview** before publishing the answers.

App Privacy answers apply at app level. Revisit them when the App Store build changes what it sends or who receives it. [Manage app privacy in App Store Connect](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
