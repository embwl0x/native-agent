import Foundation
import JavaScriptCore
import WebKit
import Testing
@testable import NativeAgentApp

/// Executes the production WebKit script without a WebKit instance, window,
/// network, or user input. Fixtures expose only the DOM boundary it consumes.
@Suite("Browser fill immediate outcome", .serialized)
@MainActor
struct BrowserFillOutcomeTests {
    @Test
    func webKitFillErrorsRetainBoundedOutcomeDetailWithoutReclassifyingFailures() {
        let detail = "Fill outcome mismatch after input/change events. Do not blindly retry."
        let failure = NSError(domain: WKError.errorDomain, code: WKError.Code.javaScriptExceptionOccurred.rawValue,
                              userInfo: ["WKJavaScriptExceptionMessage": detail])
        #expect(BrowserWindowController.fillFailure(failure).localizedDescription == "Browser fill failed: " + detail)
        let oversized = NSError(domain: WKError.errorDomain, code: WKError.Code.javaScriptExceptionOccurred.rawValue,
                                userInfo: ["WKJavaScriptExceptionMessage": String(repeating: "👁️", count: 2000)])
        #expect(BrowserWindowController.fillFailure(oversized).localizedDescription ==
                "Browser fill failed: " + String(repeating: "👁️", count: 1024))
        for error in [
            NSError(domain: WKError.errorDomain, code: WKError.Code.javaScriptExceptionOccurred.rawValue),
            NSError(domain: WKError.errorDomain, code: WKError.Code.javaScriptExceptionOccurred.rawValue,
                    userInfo: ["WKJavaScriptExceptionMessage": "  \n"]),
            NSError(domain: WKError.errorDomain, code: WKError.Code.webContentProcessTerminated.rawValue,
                    userInfo: ["WKJavaScriptExceptionMessage": detail]),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                    userInfo: ["WKJavaScriptExceptionMessage": detail]),
        ] {
            #expect((BrowserWindowController.fillFailure(error) as NSError) === error)
        }
        #expect(BrowserWindowController.fillFailure(CancellationError()) is CancellationError)
    }

    private func context(element: String, behavior: String = "") throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var events = [];
        var selected = [];
        var element = \(element);
        function Event(type, options) { this.type = type; this.bubbles = options.bubbles; }
        if(element) element.dispatchEvent = function(event) {
          events.push({type:event.type, bubbles:event.bubbles});
          \(behavior)
        };
        var document = {querySelector: function(selector) { selected.push(selector); return element; }};
        """)
        #expect(context.exception == nil)
        return context
    }

    @Test
    func fillReadsBackValueAndEditableTextWithoutChangingEventSequence() throws {
        for editable in [false, true] {
            let context = try context(element: editable
                ? "{isContentEditable:true, textContent:'before'}"
                : "{value:'before'}")
            let text = "After 🐈\nSecond line"
            context.evaluateScript(BrowserWindowController.fillScript(selector: "#target", text: text))
            #expect(context.exception == nil)
            #expect(context.evaluateScript(editable ? "element.textContent" : "element.value")?.toString() == text)
            #expect(context.evaluateScript("events.map(e => e.type + ':' + e.bubbles).join(',')")?.toString() == "input:true,change:true")
            #expect(context.evaluateScript("selected.length")?.toInt32() == 1)
            if editable {
                #expect(context.evaluateScript("'value' in element")?.toBool() == false,
                        "Contenteditable must change content, not create an invisible value property")
            }
        }
    }

    @Test
    func fillReportsSanitizationAndEventHandlerRejectionWithoutRetry() throws {
        let sanitized = try context(element: "{_value:'', get value(){return this._value}, set value(v){this._value = ''}}")
        sanitized.evaluateScript(BrowserWindowController.fillScript(selector: "#number", text: "not a number"))
        #expect(sanitized.exception?.toString().contains("Fill outcome mismatch") == true)
        #expect(sanitized.evaluateScript("selected.length")?.toInt32() == 1)

        for editable in [false, true] {
            for rejectionEvent in ["input", "change"] {
                let property = editable ? "textContent" : "value"
                let context = try context(
                    element: "{isContentEditable:\(editable), \(property):'before'}",
                    behavior: "if(event.type === '\(rejectionEvent)') this.\(property) = 'page restored';"
                )
                context.evaluateScript(BrowserWindowController.fillScript(selector: "#target", text: "requested"))
                #expect(context.exception?.toString().contains("Fill outcome mismatch") == true)
                #expect(context.evaluateScript("element.\(property)")?.toString() == "page restored")
                #expect(context.evaluateScript("events.length")?.toInt32() == 2)
                #expect(context.evaluateScript("selected.length")?.toInt32() == 1)
            }
        }
    }

    @Test
    func fillDoesNotInventValueOnNoneditableElements() throws {
        for element in ["null", "{isContentEditable:false, textContent:'unchanged'}"] {
            let context = try context(element: element)
            context.evaluateScript(BrowserWindowController.fillScript(selector: "#target", text: "requested"))
            #expect(context.exception != nil)
            #expect(context.evaluateScript("events.length")?.toInt32() == 0)
            #expect(context.evaluateScript("element ? ('value' in element) : false")?.toBool() == false)
        }
    }

    @Test
    func fillPreservesQuotedSelectorAndTextAsData() throws {
        let context = try context(element: "{value:''}")
        let selector = "[data-name=\"O'Reilly\\path\"]"
        let text = "x'; globalThis.injected = true; //\n\\\" 🐈\u{2028}\u{2029}"
        context.evaluateScript(BrowserWindowController.fillScript(selector: selector, text: text))
        #expect(context.exception == nil)
        #expect(context.evaluateScript("selected[0]")?.toString() == selector)
        #expect(context.evaluateScript("element.value")?.toString() == text)
        #expect(context.evaluateScript("typeof globalThis.injected")?.toString() == "undefined")
    }
}
