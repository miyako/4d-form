// Windows raster adapter: hidden WebView2 + Chrome DevTools Protocol capture,
// re-encoded through WIC. All form analysis and paint remain upstream.
#include "CWebView2Raster.h"

#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <objidl.h>
#include <shlwapi.h>
#include <wincodec.h>
#include <wincrypt.h>
#include <wrl.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

#include "WebView2.h"
#include "WebView2EnvironmentOptions.h"

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "version.lib")
#pragma comment(lib, "WebView2LoaderStatic.lib")

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;

namespace {

const wchar_t *kDocumentURL = L"https://fourdform.invalid/form.html";

char *duplicate(const std::string &text) {
    char *copy = static_cast<char *>(std::malloc(text.size() + 1));
    if (copy) std::memcpy(copy, text.c_str(), text.size() + 1);
    return copy;
}

std::wstring wide(const std::string &text) {
    if (text.empty()) return {};
    int count = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    std::wstring result(static_cast<size_t>(count), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), count);
    return result;
}

std::string narrow(const wchar_t *text) {
    if (!text || !*text) return {};
    int count = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
    std::string result(static_cast<size_t>(count > 0 ? count - 1 : 0), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text, -1, result.data(), count, nullptr, nullptr);
    return result;
}

std::string hresult(const char *what, HRESULT code) {
    char buffer[160];
    std::snprintf(buffer, sizeof buffer, "%s (HRESULT 0x%08lX).", what, static_cast<unsigned long>(code));
    return buffer;
}

/// JSON string literal for CDP parameters.
std::string quoted(const std::string &text) {
    std::string out = "\"";
    for (unsigned char c : text) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buffer[8];
                std::snprintf(buffer, sizeof buffer, "\\u%04x", c);
                out += buffer;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out + "\"";
}

/// Reads the JSON string value following `"key":` (first occurrence), unescaping it.
bool stringField(const std::string &json, const std::string &key, std::string &value) {
    size_t at = json.find("\"" + key + "\":");
    if (at == std::string::npos) return false;
    at = json.find('"', at + key.size() + 3);
    if (at == std::string::npos) return false;
    value.clear();
    for (size_t i = at + 1; i < json.size(); ++i) {
        char c = json[i];
        if (c == '"') return true;
        if (c != '\\' || i + 1 >= json.size()) { value += c; continue; }
        char e = json[++i];
        switch (e) {
        case 'n': value += '\n'; break;
        case 'r': value += '\r'; break;
        case 't': value += '\t'; break;
        case 'b': value += '\b'; break;
        case 'f': value += '\f'; break;
        case 'u':
            if (i + 4 < json.size()) {
                wchar_t unit = static_cast<wchar_t>(std::strtoul(json.substr(i + 1, 4).c_str(), nullptr, 16));
                wchar_t units[2] = {unit, 0};
                value += narrow(units);
                i += 4;
            }
            break;
        default: value += e;
        }
    }
    return false;
}

/// Error text from a CDP Runtime.evaluate exception, if any.
bool exceptionText(const std::string &json, std::string &message) {
    size_t at = json.find("\"exceptionDetails\"");
    if (at == std::string::npos) return false;
    std::string tail = json.substr(at);
    if (!stringField(tail, "description", message) && !stringField(tail, "text", message)) {
        message = "Script exception in WebView2.";
    }
    // Keep the exception message, not the anonymous script stack.
    size_t stack = message.find("\n    at ");
    if (stack != std::string::npos) message.erase(stack);
    if (message.rfind("Error: ", 0) == 0) message.erase(0, 7);
    return true;
}

struct Raster {
    std::string html;
    std::string prepare;
    std::string resize;
    fourdform_size_callback sizeCallback = nullptr;
    void *context = nullptr;

    HWND window = nullptr;
    ComPtr<ICoreWebView2Environment> environment;
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> webView;
    bool finished = false;
    bool settled = true;
    bool browserExited = false;
    std::string failure;
    std::vector<unsigned char> png;
    int pixelWidth = 0;
    int pixelHeight = 0;

    void fail(const std::string &message) {
        if (finished) return;
        failure = message;
        finished = true;
    }

    void cdp(const wchar_t *method, const std::string &params,
             std::function<void(const std::string &)> next) {
        HRESULT hr = webView->CallDevToolsProtocolMethod(method, wide(params).c_str(),
            Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
                [this, method, next](HRESULT error, LPCWSTR json) -> HRESULT {
                    if (finished) return S_OK;
                    std::string result = narrow(json);
                    if (FAILED(error)) {
                        std::string detail;
                        stringField(result, "message", detail);
                        fail("WebView2 " + narrow(method) + " failed" + (detail.empty() ? "." : ": " + detail));
                        return S_OK;
                    }
                    next(result);
                    return S_OK;
                }).Get());
        if (FAILED(hr)) fail(hresult("Cannot call WebView2 DevTools protocol", hr));
    }

    void evaluate(const std::string &expression, std::function<void(const std::string &)> next) {
        cdp(L"Runtime.evaluate",
            "{\"expression\":" + quoted(expression) +
                ",\"awaitPromise\":true,\"returnByValue\":true,\"userGesture\":false}",
            [this, next](const std::string &json) {
                std::string message;
                if (exceptionText(json, message)) { fail(message); return; }
                next(json);
            });
    }

    void start() {
        auto options = Make<CoreWebView2EnvironmentOptions>();
        // sRGB output, software paint, no DNS/proxy/background services.
        options->put_AdditionalBrowserArguments(
            L"--force-color-profile=srgb --disable-gpu --disable-lcd-text --no-proxy-server "
            L"--host-resolver-rules=\"MAP * ~NOTFOUND\" --disable-background-networking "
            L"--disable-component-update --disable-sync --disable-domain-reliability "
            L"--disable-features=msSmartScreenProtection,msEdgeTranslate,AutofillServerCommunication");
        options->put_AllowSingleSignOnUsingOSPrimaryAccount(FALSE);
        wchar_t temp[MAX_PATH + 1];
        DWORD length = GetTempPathW(MAX_PATH + 1, temp);
        GUID guid;
        CoCreateGuid(&guid);
        wchar_t name[64];
        StringFromGUID2(guid, name, 64);
        userData = std::wstring(temp, length) + L"fourdform-webview2-" + name;
        settled = false;
        HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(nullptr, userData.c_str(), options.Get(),
            Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                [this](HRESULT result, ICoreWebView2Environment *created) -> HRESULT {
                    if (FAILED(result) || !created) {
                        fail(hresult("Cannot start the Microsoft Edge WebView2 Runtime", result));
                        settled = true;
                        return S_OK;
                    }
                    environment = created;
                    ComPtr<ICoreWebView2Environment5> exitable;
                    if (SUCCEEDED(environment.As(&exitable))) {
                        exitable->add_BrowserProcessExited(
                            Callback<ICoreWebView2BrowserProcessExitedEventHandler>(
                                [this](ICoreWebView2Environment *, ICoreWebView2BrowserProcessExitedEventArgs *) -> HRESULT {
                                    browserExited = true;
                                    return S_OK;
                                }).Get(), nullptr);
                    } else {
                        browserExited = true;
                    }
                    if (finished) { settled = true; return S_OK; }
                    HRESULT hr = environment->CreateCoreWebView2Controller(window,
                        Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                            [this](HRESULT result, ICoreWebView2Controller *created) -> HRESULT {
                                settled = true;
                                if (created) {
                                    controller = created;
                                    controller->get_CoreWebView2(&webView);
                                }
                                if (finished) return S_OK;
                                if (FAILED(result) || !created) {
                                    fail(hresult("Cannot create a WebView2 controller", result));
                                    return S_OK;
                                }
                                configure();
                                return S_OK;
                            }).Get());
                    if (FAILED(hr)) {
                        settled = true;
                        fail(hresult("Cannot create a WebView2 controller", hr));
                    }
                    return S_OK;
                }).Get());
        if (FAILED(hr)) {
            settled = true;
            fail(hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)
                     ? std::string("The Microsoft Edge WebView2 Runtime is not installed.")
                     : hresult("Cannot start the Microsoft Edge WebView2 Runtime", hr));
        }
    }

    void configure() {
        ComPtr<ICoreWebView2Controller3> scaled;
        if (SUCCEEDED(controller.As(&scaled))) {
            scaled->put_ShouldDetectMonitorScaleChanges(FALSE);
            scaled->put_BoundsMode(COREWEBVIEW2_BOUNDS_MODE_USE_RAW_PIXELS);
            scaled->put_RasterizationScale(1.0);
        }
        ComPtr<ICoreWebView2Controller2> background;
        if (SUCCEEDED(controller.As(&background))) {
            background->put_DefaultBackgroundColor(COREWEBVIEW2_COLOR{255, 255, 255, 255});
        }
        controller->put_Bounds(RECT{0, 0, 16, 16});
        controller->put_IsVisible(TRUE);
        if (!webView) { fail("WebView2 did not provide a web view."); return; }

        ComPtr<ICoreWebView2Settings> settings;
        webView->get_Settings(&settings);
        if (settings) {
            settings->put_AreDefaultContextMenusEnabled(FALSE);
            settings->put_AreDefaultScriptDialogsEnabled(FALSE);
            settings->put_IsStatusBarEnabled(FALSE);
            settings->put_IsWebMessageEnabled(FALSE);
            settings->put_AreHostObjectsAllowed(FALSE);
            settings->put_IsZoomControlEnabled(FALSE);
            settings->put_AreDevToolsEnabled(FALSE);
            settings->put_IsBuiltInErrorPageEnabled(FALSE);
        }
        ComPtr<ICoreWebView2Settings4> autofill;
        if (settings && SUCCEEDED(settings.As(&autofill))) {
            autofill->put_IsGeneralAutofillEnabled(FALSE);
            autofill->put_IsPasswordAutosaveEnabled(FALSE);
        }
        ComPtr<ICoreWebView2_13> withProfile;
        if (SUCCEEDED(webView.As(&withProfile))) {
            ComPtr<ICoreWebView2Profile> profile;
            if (SUCCEEDED(withProfile->get_Profile(&profile)) && profile) {
                profile->put_PreferredColorScheme(COREWEBVIEW2_PREFERRED_COLOR_SCHEME_LIGHT);
            }
        }

        webView->add_ProcessFailed(
            Callback<ICoreWebView2ProcessFailedEventHandler>(
                [this](ICoreWebView2 *, ICoreWebView2ProcessFailedEventArgs *args) -> HRESULT {
                    COREWEBVIEW2_PROCESS_FAILED_KIND kind;
                    args->get_ProcessFailedKind(&kind);
                    fail("WebView2 content process failed (kind " + std::to_string(static_cast<int>(kind)) + ").");
                    return S_OK;
                }).Get(), nullptr);

        // Serve only the in-memory document; refuse every other request.
        webView->AddWebResourceRequestedFilter(L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
        webView->add_WebResourceRequested(
            Callback<ICoreWebView2WebResourceRequestedEventHandler>(
                [this](ICoreWebView2 *, ICoreWebView2WebResourceRequestedEventArgs *args) -> HRESULT {
                    ComPtr<ICoreWebView2WebResourceRequest> request;
                    args->get_Request(&request);
                    LPWSTR uri = nullptr;
                    if (request) request->get_Uri(&uri);
                    bool document = uri && std::wcscmp(uri, kDocumentURL) == 0;
                    CoTaskMemFree(uri);
                    ComPtr<IStream> body;
                    if (document) {
                        body.Attach(SHCreateMemStream(reinterpret_cast<const BYTE *>(html.data()),
                                                      static_cast<UINT>(html.size())));
                    }
                    ComPtr<ICoreWebView2WebResourceResponse> response;
                    environment->CreateWebResourceResponse(
                        body.Get(), document ? 200 : 403, document ? L"OK" : L"Forbidden",
                        document ? L"Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store"
                                 : L"Content-Type: text/plain",
                        &response);
                    args->put_Response(response.Get());
                    return S_OK;
                }).Get(), nullptr);

        webView->add_NavigationCompleted(
            Callback<ICoreWebView2NavigationCompletedEventHandler>(
                [this](ICoreWebView2 *, ICoreWebView2NavigationCompletedEventArgs *args) -> HRESULT {
                    if (finished) return S_OK;
                    BOOL success = FALSE;
                    args->get_IsSuccess(&success);
                    if (!success) {
                        COREWEBVIEW2_WEB_ERROR_STATUS status;
                        args->get_WebErrorStatus(&status);
                        fail("WebView2 navigation failed (status " + std::to_string(static_cast<int>(status)) + ").");
                        return S_OK;
                    }
                    prepareCanvas();
                    return S_OK;
                }).Get(), nullptr);

        cdp(L"Emulation.setEmulatedMedia",
            "{\"media\":\"screen\",\"features\":[{\"name\":\"prefers-color-scheme\",\"value\":\"light\"},"
            "{\"name\":\"prefers-reduced-motion\",\"value\":\"reduce\"}]}",
            [this](const std::string &) {
                HRESULT hr = webView->Navigate(kDocumentURL);
                if (FAILED(hr)) fail(hresult("Cannot load the form document in WebView2", hr));
            });
    }

    void prepareCanvas() {
        evaluate("(async () => { const size = await (async () => {\n" + prepare +
                     "\n})(); return String(size.width) + ' ' + String(size.height); })()",
                 [this](const std::string &json) {
                     std::string value;
                     double width = 0, height = 0;
                     if (!stringField(json, "value", value) ||
                         std::sscanf(value.c_str(), "%lf %lf", &width, &height) != 2) {
                         fail("WebView2 returned invalid canvas dimensions.");
                         return;
                     }
                     char *message = nullptr;
                     if (sizeCallback(context, width, height, &pixelWidth, &pixelHeight, &message) != 0) {
                         fail(message ? message : "Invalid canvas or raster limits.");
                         std::free(message);
                         return;
                     }
                     resizeAndCapture();
                 });
    }

    void resizeAndCapture() {
        SetWindowPos(window, nullptr, -32000, -32000, pixelWidth, pixelHeight,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        controller->put_Bounds(RECT{0, 0, pixelWidth, pixelHeight});
        std::string w = std::to_string(pixelWidth), h = std::to_string(pixelHeight);
        cdp(L"Emulation.setDeviceMetricsOverride",
            "{\"width\":" + w + ",\"height\":" + h + ",\"deviceScaleFactor\":1,\"mobile\":false}",
            [this, w, h](const std::string &) {
                // Two animation frames after resizing: layout and paint are committed.
                evaluate("(async (width, height) => {\n" + resize +
                             "\nawait new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));"
                             "\nreturn 'ok'; })(" + w + ", " + h + ")",
                         [this, w, h](const std::string &) {
                             cdp(L"Page.captureScreenshot",
                                 "{\"format\":\"png\",\"fromSurface\":true,\"captureBeyondViewport\":false,"
                                 "\"clip\":{\"x\":0,\"y\":0,\"width\":" + w + ",\"height\":" + h + ",\"scale\":1}}",
                                 [this](const std::string &json) { encode(json); });
                         });
            });
    }

    void encode(const std::string &json) {
        std::string data;
        if (!stringField(json, "data", data) || data.empty()) {
            fail("WebView2 did not produce a raster image.");
            return;
        }
        DWORD size = 0;
        if (!CryptStringToBinaryA(data.c_str(), static_cast<DWORD>(data.size()), CRYPT_STRING_BASE64,
                                  nullptr, &size, nullptr, nullptr)) {
            fail("WebView2 returned an undecodable raster image.");
            return;
        }
        std::vector<unsigned char> captured(size);
        CryptStringToBinaryA(data.c_str(), static_cast<DWORD>(data.size()), CRYPT_STRING_BASE64,
                             captured.data(), &size, nullptr, nullptr);
        std::string error;
        if (!reencode(captured, error)) { fail(error); return; }
        finished = true;
    }

    /// Decodes the capture and writes an exact-size 8-bit RGBA PNG (color type 6).
    bool reencode(const std::vector<unsigned char> &captured, std::string &error) {
        ComPtr<IWICImagingFactory> factory;
        HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
        ComPtr<IWICStream> input;
        ComPtr<IWICBitmapDecoder> decoder;
        ComPtr<IWICBitmapFrameDecode> frame;
        if (SUCCEEDED(hr)) hr = factory->CreateStream(&input);
        if (SUCCEEDED(hr)) hr = input->InitializeFromMemory(const_cast<BYTE *>(captured.data()), static_cast<DWORD>(captured.size()));
        if (SUCCEEDED(hr)) hr = factory->CreateDecoderFromStream(input.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder);
        if (SUCCEEDED(hr)) hr = decoder->GetFrame(0, &frame);
        if (FAILED(hr)) { error = hresult("WebView2 did not produce a decodable raster image", hr); return false; }
        UINT width = 0, height = 0;
        frame->GetSize(&width, &height);
        ComPtr<IWICBitmapSource> source = frame;
        if (width != static_cast<UINT>(pixelWidth) || height != static_cast<UINT>(pixelHeight)) {
            ComPtr<IWICBitmapScaler> scaler;
            hr = factory->CreateBitmapScaler(&scaler);
            if (SUCCEEDED(hr)) hr = scaler->Initialize(frame.Get(), pixelWidth, pixelHeight, WICBitmapInterpolationModeHighQualityCubic);
            if (FAILED(hr)) { error = hresult("Cannot scale raster image", hr); return false; }
            source = scaler;
        }
        ComPtr<IWICFormatConverter> converter;
        hr = factory->CreateFormatConverter(&converter);
        if (SUCCEEDED(hr)) hr = converter->Initialize(source.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
                                                      nullptr, 0, WICBitmapPaletteTypeCustom);
        if (FAILED(hr)) { error = hresult("Cannot convert raster image", hr); return false; }
        std::vector<unsigned char> pixels(static_cast<size_t>(pixelWidth) * pixelHeight * 4);
        hr = converter->CopyPixels(nullptr, pixelWidth * 4, static_cast<UINT>(pixels.size()), pixels.data());
        if (FAILED(hr)) { error = hresult("Cannot read raster pixels", hr); return false; }

        ComPtr<IStream> output;
        output.Attach(SHCreateMemStream(nullptr, 0));
        ComPtr<IWICBitmapEncoder> encoder;
        ComPtr<IWICBitmapFrameEncode> target;
        if (!output) hr = E_OUTOFMEMORY;
        if (SUCCEEDED(hr)) hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
        if (SUCCEEDED(hr)) hr = encoder->Initialize(output.Get(), WICBitmapEncoderNoCache);
        if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&target, nullptr);
        if (SUCCEEDED(hr)) hr = target->Initialize(nullptr);
        if (SUCCEEDED(hr)) hr = target->SetSize(pixelWidth, pixelHeight);
        WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
        if (SUCCEEDED(hr)) hr = target->SetPixelFormat(&format);
        if (SUCCEEDED(hr) && format != GUID_WICPixelFormat32bppBGRA) hr = WINCODEC_ERR_UNSUPPORTEDPIXELFORMAT;
        if (SUCCEEDED(hr)) hr = target->WritePixels(pixelHeight, pixelWidth * 4, static_cast<UINT>(pixels.size()), pixels.data());
        if (SUCCEEDED(hr)) hr = target->Commit();
        if (SUCCEEDED(hr)) hr = encoder->Commit();
        STATSTG stat{};
        if (SUCCEEDED(hr)) hr = output->Stat(&stat, STATFLAG_NONAME);
        if (SUCCEEDED(hr)) hr = output->Seek(LARGE_INTEGER{}, STREAM_SEEK_SET, nullptr);
        if (SUCCEEDED(hr)) {
            png.resize(static_cast<size_t>(stat.cbSize.QuadPart));
            ULONG read = 0;
            hr = output->Read(png.data(), static_cast<ULONG>(png.size()), &read);
            if (SUCCEEDED(hr) && read != png.size()) hr = E_FAIL;
        }
        if (FAILED(hr)) { error = hresult("PNG encoding failed", hr); return false; }
        return true;
    }

    std::wstring userData;
};

LRESULT CALLBACK windowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    return DefWindowProcW(window, message, wParam, lParam);
}

void pump(const bool &done, ULONGLONG deadline) {
    while (!done) {
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) return;
        DWORD wait = static_cast<DWORD>(std::min<ULONGLONG>(deadline - now, 50));
        MsgWaitForMultipleObjectsEx(0, nullptr, wait, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
}

}  // namespace

extern "C" int fourdform_webview2_png(const char *html, size_t html_length,
                                      const char *prepare_js, const char *resize_js,
                                      fourdform_size_callback size_callback, void *context,
                                      double timeout_seconds,
                                      unsigned char **png, size_t *png_length, char **error) {
    *png = nullptr;
    *png_length = 0;
    *error = nullptr;
    if (!(timeout_seconds >= 0) || !std::isfinite(timeout_seconds) || timeout_seconds > 600) {
        *error = duplicate("Invalid rasterization timeout.");
        return 1;
    }
    if (html_length > 512u * 1024u * 1024u) {
        *error = duplicate("Rendered form document is too large.");
        return 1;
    }
    HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(initialized) && initialized != RPC_E_CHANGED_MODE) {
        *error = duplicate(hresult("Cannot initialize COM", initialized));
        return 1;
    }
    ULONGLONG start = GetTickCount64();
    ULONGLONG deadline = start + static_cast<ULONGLONG>(timeout_seconds * 1000.0);

    Raster raster;
    raster.html.assign(html, html_length);
    raster.prepare = prepare_js;
    raster.resize = resize_js;
    raster.sizeCallback = size_callback;
    raster.context = context;

    HINSTANCE instance = GetModuleHandleW(nullptr);
    const wchar_t *className = L"FourDFormWebView2Raster";
    WNDCLASSEXW windowClass{sizeof windowClass};
    windowClass.lpfnWndProc = windowProcedure;
    windowClass.hInstance = instance;
    windowClass.lpszClassName = className;
    RegisterClassExW(&windowClass);
    raster.window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, className, L"fourdform",
                                    WS_POPUP, -32000, -32000, 16, 16, nullptr, nullptr, instance, nullptr);
    if (!raster.window) {
        raster.fail("Cannot create the hidden rasterization window.");
    } else {
        ShowWindow(raster.window, SW_SHOWNOACTIVATE);
        if (timeout_seconds > 0) raster.start();
        pump(raster.finished, deadline);
    }
    if (!raster.finished) {
        char buffer[96];
        std::snprintf(buffer, sizeof buffer, "Rasterization timed out after %d seconds.", static_cast<int>(timeout_seconds));
        raster.fail(buffer);
    }

    // Tear down the browser and remove its private profile. Creation callbacks
    // still in flight are drained first so no browser process is orphaned.
    pump(raster.settled, GetTickCount64() + 10000);
    HANDLE browser = nullptr;
    UINT32 browserId = 0;
    if (raster.webView && SUCCEEDED(raster.webView->get_BrowserProcessId(&browserId)) && browserId) {
        browser = OpenProcess(SYNCHRONIZE, FALSE, browserId);
    }
    if (raster.controller) raster.controller->Close();
    raster.webView.Reset();
    raster.controller.Reset();
    if (browser) {
        // Releasing every reference lets the private browser exit promptly.
        raster.environment.Reset();
        ULONGLONG limit = GetTickCount64() + 10000;
        while (GetTickCount64() < limit) {
            DWORD wait = MsgWaitForMultipleObjectsEx(1, &browser, 50, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
            if (wait == WAIT_OBJECT_0) break;
            MSG message;
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        CloseHandle(browser);
    } else if (raster.environment) {
        pump(raster.browserExited, GetTickCount64() + 10000);
        raster.environment.Reset();
    }
    if (raster.window) DestroyWindow(raster.window);
    UnregisterClassW(className, instance);
    if (!raster.userData.empty()) {
        std::error_code ignored;
        for (int attempt = 0; attempt < 20; ++attempt) {
            std::filesystem::remove_all(raster.userData, ignored);
            if (!std::filesystem::exists(raster.userData, ignored)) break;
            bool never = false;
            pump(never, GetTickCount64() + 100);
        }
    }
    if (SUCCEEDED(initialized)) CoUninitialize();

    if (!raster.failure.empty() || raster.png.empty()) {
        *error = duplicate(raster.failure.empty() ? std::string("WebView2 did not produce a PNG.") : raster.failure);
        return 1;
    }
    *png = static_cast<unsigned char *>(std::malloc(raster.png.size()));
    if (!*png) {
        *error = duplicate("Out of memory.");
        return 1;
    }
    std::memcpy(*png, raster.png.data(), raster.png.size());
    *png_length = raster.png.size();
    return 0;
}

extern "C" int fourdform_wic_decode_png(const unsigned char *png, size_t png_length,
                                        int *width, int *height, unsigned char **rgba, char **error) {
    *rgba = nullptr;
    *error = nullptr;
    HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ComPtr<IWICImagingFactory> factory;
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    ComPtr<IWICFormatConverter> converter;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
    if (SUCCEEDED(hr)) hr = factory->CreateStream(&stream);
    if (SUCCEEDED(hr)) hr = stream->InitializeFromMemory(const_cast<BYTE *>(png), static_cast<DWORD>(png_length));
    if (SUCCEEDED(hr)) hr = factory->CreateDecoder(GUID_ContainerFormatPng, nullptr, &decoder);
    if (SUCCEEDED(hr)) hr = decoder->Initialize(stream.Get(), WICDecodeMetadataCacheOnDemand);
    if (SUCCEEDED(hr)) hr = decoder->GetFrame(0, &frame);
    UINT w = 0, h = 0;
    if (SUCCEEDED(hr)) hr = frame->GetSize(&w, &h);
    if (SUCCEEDED(hr)) hr = factory->CreateFormatConverter(&converter);
    if (SUCCEEDED(hr)) hr = converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone,
                                                  nullptr, 0, WICBitmapPaletteTypeCustom);
    if (SUCCEEDED(hr) && (w == 0 || h == 0 || w > 65536 || h > 65536)) hr = E_INVALIDARG;
    if (SUCCEEDED(hr)) {
        *rgba = static_cast<unsigned char *>(std::malloc(static_cast<size_t>(w) * h * 4));
        hr = *rgba ? converter->CopyPixels(nullptr, w * 4, w * h * 4, *rgba) : E_OUTOFMEMORY;
    }
    converter.Reset(); frame.Reset(); decoder.Reset(); stream.Reset(); factory.Reset();
    if (SUCCEEDED(initialized)) CoUninitialize();
    if (FAILED(hr)) {
        std::free(*rgba);
        *rgba = nullptr;
        *error = duplicate(hresult("PNG decoding failed", hr));
        return 1;
    }
    *width = static_cast<int>(w);
    *height = static_cast<int>(h);
    return 0;
}

extern "C" void fourdform_free(void *pointer) { std::free(pointer); }

#endif
