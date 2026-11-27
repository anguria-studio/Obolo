# Mac App Store privacy answers

Use this guide for the build archived from [project-store.yml](../project-store.yml). The public [privacy policy](privacy.md) also covers the direct-download edition.

## Data collection

For this Store build, choose **No, we do not collect data from this app**. Apple displays **Data Not Collected**.

Apple's label covers data available to the developer or its third-party partners beyond the time needed to handle the request. Apple excludes data it collects for its own services. On-device processing is outside the label. Optional features can still require disclosure. [Apple's App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)

| Store build feature | App Store Connect treatment |
| --- | --- |
| Local library, backups, reminders and file import or export | Leave these out of Data Types. Obolo processes them on the Mac or writes files where the user directs it. |
| CloudKit sync | Leave the private iCloud records out of Data Types. The app accesses the records in the signed-in user's private database. Anguria Studio receives no copy and has no access to that database. The CloudKit account record name stays in local sync state. [Apple's private CloudKit database documentation](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase) |
| Calendar events | Leave these out of Data Types. With permission, Obolo writes events through macOS to the chosen calendar. Events contain the subscription name, amount and currency, dates and recurrence, notes and optional alerts. The provider and people who share that calendar may receive them, even with Obolo’s iCloud sync off. Anguria Studio receives no copy. |
| Frankfurter rates | Leave these out of Data Types. Requests include base and target currency codes. Frankfurter says it retains no request URLs or IP address logs, and its Cloudflare setup provides aggregate traffic statistics. [Frankfurter's privacy FAQ](https://frankfurter.dev/#faq) |
| Website icons | The Mac contacts the website the user supplied and any icon hosts or redirects that website specifies. Obolo contacts these destinations directly. It sends no copy of those requests to Anguria Studio. |
| Updates, analytics and advertising | The Store edition uses Apple's update system. It includes no Sparkle updater, telemetry, advertising code or tracking SDK. |

## Website icon requests

[LogoFetcher](../App/Services/LogoFetcher.swift) starts with a GET to the root of the [normalized host](../Core/Sources/OboloCore/Model/Subscription.swift). The starting request excludes the management link’s path, query and fragment. Obolo follows redirects, reads icon links from the HTML, and can try conventional icon paths. The site controls its redirects and icon URLs, including their hosts, paths and query strings. The app uses an ephemeral URL session with cookies and the URL cache disabled. It does not execute JavaScript or send the subscription name, amount, notes or library as a request payload.

These requests can occur on save, on import with logo fetching enabled, and when fetching logos manually. A one-time check for existing logos and the arrival of a synced logo can also trigger a dark-icon request. An origin or icon host can see the user’s IP address, requested URL and request headers. Each host controls its own logs.

**Basis for the label.** These are requests to independent sites identified by the user’s subscription or by the site itself. Obolo integrates no icon-provider SDK and uses no studio-operated proxy or fixed logo service in the Store edition. The icon feature gives Anguria Studio no access to the hosts’ traffic or logs. On that basis, we treat the sites as destinations for the user’s content, outside collection by the developer or its integrated partners. This assessment does not depend on the sites deleting their logs. A user can enter a Google-owned site, and a website can point to a Google-hosted image. The Store app has no built-in Google favicon fallback, even if a restored backup has that preference enabled.

Reassess this answer if the studio chooses a logo provider, adds an SDK, or gains access to request logs. [Apple’s definitions of collection and third-party partners](https://developer.apple.com/app-store/app-privacy-details/)

## Listing and release check

The canonical policy URL is [https://github.com/anguria-studio/Obolo/blob/main/docs/privacy.md](https://github.com/anguria-studio/Obolo/blob/main/docs/privacy.md).

1. Once the policy is on `main`, open the policy URL signed out of GitHub.
2. Open **Help → Privacy Policy** in the release build. Verify that it opens the same page.
3. In App Store Connect, open **Obolo → App Privacy**. Set the macOS **Privacy Policy URL** and save.
4. Complete **Data Collection** using the answer above. Review the **Product Page Preview** before publishing the answers.

App Privacy answers apply at app level. Revisit them when the App Store build changes what it sends or who receives it. [Manage app privacy in App Store Connect](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
