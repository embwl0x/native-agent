<!-- url: https://developer.chrome.com/docs/webstore/best-practices -->
<!-- fetched: 2026-09-17 -->

-

Home

-

Docs

-

Chrome Extensions

-

Chrome Web Store

##
Best Practices

Stay organized with collections

Save and categorize content based on your preferences.

## Overview

This page provides guidelines for designing a high-quality extension and Chrome Web Store listing. These recommendations may be updated as the store continues to grow and we learn from developers' experiences. We strongly encourage you to create extensions that meet standards for compliance, performance, security, and user experience, as described in the following sections.

## Compliance

Extensions that are available in the Chrome Web Store are required to adhere to the developer program policies . If you've received a policy violation warning or want to learn about common violations pitfalls, see Troubleshooting Chrome Web Store violations .

## Manifest Version 3

Manifest V3 is the most recent version of the Chrome extension platform and is the required version for submitting new items to the Chrome Web Store. See the Manifest V3 overview to learn about the platform changes. Existing extensions should consider migrating to Manifest V3, see Migrate to Manifest V3 for instructions on how to migrate.

## Security

Your extension should be safe for your users. For example, send user data securely via HTTPS or web services security. Check that your extension does not pose security threats and does not use deceptive installation tactics . See Stay secure for a more information.

## Privacy

An extension is required to disclose in the Privacy tab what user data it will collect and how it will handle user data. This information must be accurate, up-to-date, and match the extension's privacy policy . For more guidance on privacy, see Protecting User Privacy policies and the User Data FAQs .

## Performance and functionality

## Performance Tooling

Add end-to-end tests using testing libraries like Puppeteer to make sure your extension is performing as intended from start to finish. In addition, consider conducting thorough manual testing across different browser versions, OSs, and network conditions to ensure smooth functionality.

## Avoiding performance pitfalls

When you are releasing your extension, there are a number of common performance issues you should make sure to avoid.

## Back/Forward cache invalidation

The back/forward cache is an optimization built into Chrome that allows for instant loading of a page when a user returns to it. Given extensions can run on every page, its essential you make sure avoid code that prevents that caching, or else you risk substantially slowing down your users. Make sure you test if your extension invalidates the cache. Common causes of cache invalidation include

Unload Handler
The unload handler has been deprecated for a long time and should generally never be used. If you are using it, pagehide event is the most popular alternative. If you need to run code after the page closes, there is chrome.tabs.onRemoved .

WebSockets in content scripts
If you have a content script with a WebSocket or WebRTC connection, then the page cannot be cached. You can instead move these connections to your background service worker script . We have a guide on how to keep your connection in a background script, and then proxy the results to your content script with runtime.connect .

## User experience

Design your extension with the user in mind by providing a simple, intuitive, and seamless user interface while also respecting user privacy.

## Onboarding experience

Start onboarding your users as soon as they reach your store listing by providing screenshots and a video of how the extension works. We recommend following the permission warning guidelines to increase the chances of users installing your extension.

## Designing a persistent UI

Avoid distracting users when implementing a persistent UI. For example, when designing a side panel for your extension, make sure it enhances the user's browsing experience by providing relevant information and useful functionality. A side panel should help users accomplish tasks with as little distraction as possible.

## Sign in with Google

If your extension requires user login, we recommend that you support Sign in with Google , which provides a good user experience for Chrome Web Store users as they are likely to be logged in already. If you already have a login system, consider correlating the Google Account ID to the user account in your system. You can use the Chrome Identity API to support Google accounts in the following ways:

- OAuth2: See Authenticate users with Google .

## Store listing

The purpose of an extension's Chrome Web Store store listing is to set the user's expectations. It should explicitly communicate what the extension does. See Listing requirements for a complete list of requirements.

## Create a compelling store listing

The better your extension's store listing, the more users will discover and try your extension. Creating a great listing page provides guidelines for designing the best store listing experience. When choosing your extension's name, writing its description, and designing its logo, keep in mind Google's Branding guidelines .

## Provide great images

Include all the required images (icon, tile, marquee, and screenshots). Images should not be blurry or too busy, as described in Images of a high-quality listing .

## Choose your extension's category well

The developer dashboard requires you to specify a category for your extension. Choose the most appropriate category:

Accessibility
Extensions designed to enhance the browsing experience for individuals with visual impairments, hearing loss, limited dexterity, and other disabilities. This may include tools like screen readers, dark mode extensions, or utilities that help with navigation, using keyboard shortcuts, voice commands, among others.
Art & Design
These extensions provide tools for viewing, editing, organizing, and sharing images and photos. They may also offer features for capturing screenshots, image searching, and integrating with popular image hosting or editing services.
Communication
Extensions that enable communications. This category covers a wide variety of things: composing and templating emails, email management, screen sharing, video conferencing apps and enhancements, and much more.
Developer Tools
Extensions that help web developers perform tasks like debugging, performance analysis, code linting, and tools that enhance the browser's Dev Tools. For example, real-time HTML/CSS/JavaScript editing, API testing, and CSS inspection.
Education
Extensions that teach or aid in teaching, including language learning, note-taking, teaching aids, and sign-language instruction, among others.
Entertainment
These extensions are designed for fans of sports, music, television, and cinema.
Functionality & UI
Extensions that enhance the Chrome user interface, such as tab managers, shortcut managers, and app launchers.
Games
Extensions providing a wide array of desktop and arcade-style games.
Household
Extensions for helping you around the house. This category includes recipe savers and managers, budgeting, product research, and more.
Just for Fun
These extensions are designed for entertainment. They can include games, interesting new tab backgrounds, quirky widgets, jokes, trivia, and more.
News & Weather
These extensions keep users informed about current events and weather conditions. They can collect news from multiple sources, present real-time weather updates, notify breaking news, and more.
Privacy & Security
Extensions such as VPNs, password safes, and phishing deterrence.
Shopping
These extensions aim to enhance the online shopping experience. They might offer features like price comparison, coupon finders, reviews and ratings, wish list management, and more.
Social Media & Networking
These extensions are designed to enhance social media platforms. They can integrate with services and offer features like easy sharing, notifications, status updates, and more.
Tools
Tools that don't fit into other categories
Travel
Extensions for planning trips.
Well-being
Extensions for self-help, mindfulness, and personal development.
Workflow & Planning
Extensions to help users perform their tasks more efficiently. They could range from time trackers, tools to stay focused, to-do list managers, email organizers, document editors, and calendar utilities, among others.

## Category revisions

In mid 2023 the categories changed. Most of the new categories match previous ones. Several were
replaced by multiple categories. If you previously used one of the replaced categories, use the
table below to decide which new category best suits your extension.

Fun
* Entertainment

- Games

- Just for Fun

Photos
* Art & Design
Productivity
* Education

- Functionality & UI

- Household

- Privacy & Security

- Tools

- Workflow & Planning

Social & Communications
* Communication

- Social Media & Networking

- Travel

- Well-being

## Choose your theme's category well

The developer dashboard also asks you specify a category for your theme. Choose the most appropriate category:

Animals
Themes inspired by animals.
Art & Design
Themes built merely to make your browser look pretty.
Cars
Themes relating to cars, such as current and classic cars.
Colors
Themes that skin your browser in custom colors.
Dark & Black
Themes that feature dark colors and imagery.
Entertainment
Themes inspired by popular entertainment, such as television and film franchises.
Games & Anime
Themes inspired by video games and anime.
Minimalist
Themes that simplify the look of your browser.
Nature & Landscapes
Themes inspired by the great outdoors.
Space
Themes inspired by space.
Other
A category for themes that don't have a home anywhere else.
