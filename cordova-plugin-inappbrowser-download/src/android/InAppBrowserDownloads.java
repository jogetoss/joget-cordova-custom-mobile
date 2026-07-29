package org.apache.cordova.inappbrowser;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.util.Log;

import org.apache.cordova.CordovaWebView;
import org.json.JSONException;

//Download Files imports
import android.app.DownloadManager;
import android.os.Environment;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.URLUtil;
import android.widget.Toast;
import android.webkit.WebView;
import android.webkit.JavascriptInterface;
import java.io.FileOutputStream;
import java.text.SimpleDateFormat;
import java.util.Date;

//Open attachment imports
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.IntentFilter;
import android.content.ContentResolver;
import android.database.Cursor;
import android.support.v4.content.FileProvider;
import java.io.File;
import java.nio.charset.StandardCharsets;

import static android.content.Context.DOWNLOAD_SERVICE;

//Permissions
import android.content.pm.PackageManager;

public class InAppBrowserDownloads implements DownloadListener {

    InAppBrowser plugin;
    WebView inAppWebView;

    String url;
    String userAgent;
    String contentDisposition;
    String mimetype;
    long contentLength;

    public InAppBrowserDownloads(InAppBrowser plugin, WebView inAppWebView) {
        this.plugin = plugin;
        this.inAppWebView = inAppWebView;

        // Register JavaScript interface for handling blob URLs and data URIs file download
        inAppWebView.addJavascriptInterface(new BlobDownloader(), "CordovaBlobDownloader");
    }

    /**
     * the blob hook javascript injection definition which is used to catch blob files for download
     */
    public String getBlobHookJavaScript() {
        // stores blobs with unique IDs for reliable retrieval
        String JS_BLOB_HOOK = 
        "(function() {" +
            "  if (window.__blobHookInstalled) {" +
            "    console.log('Blob hook already installed');" +
            "    return;" +
            "  }" +
            "  window.__blobHookInstalled = true;" +
            "  console.log('Installing improved blob hook with ID-based storage');" +
            "  " +
            "  window.__jogetBlobStore = window.__jogetBlobStore || {};" +
            "  " +
            "  const originalCreateObjectURL = URL.createObjectURL;" +
            "  URL.createObjectURL = function(blob) {" +
            "    const id = 'blob_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);" +
            "    " +
            "    window.__jogetBlobStore[id] = blob;" +
            "    " +
            "    const originalUrl = originalCreateObjectURL(blob);" +
            "    " +
            "    window.__jogetBlobStore[originalUrl] = id;" +
            "    " +
            "    console.log('Blob stored - ID:', id, 'URL:', originalUrl, 'size:', blob.size, 'type:', blob.type);" +
            "    " +
            "    return originalUrl;" +
            "  };" +
            "  " +
            "  console.log('Improved blob hook installed successfully');" +
            "})();";

        return JS_BLOB_HOOK;
    }

    /**
     * JavaScript interface for handling blob URLs and data URIs file download
     * 
     * This interface is used to receive the blob captured from JavaScript
     * and handle them in the Android environment to enable the file to be downloaded locally
     * 
     * This was scooped up from 
     * https://proandroiddev.com/blob-downloads-not-working-in-android-web-view-heres-the-real-fix-243144a2a426
     * 
     */
    private class BlobDownloader {
        private boolean isActive = true;

        @JavascriptInterface
        public void onDownloadPreparing() {
            plugin.cordova.getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    Toast.makeText(plugin.cordova.getActivity().getApplicationContext(),
                            "Preparing file…", Toast.LENGTH_SHORT).show();
                }
            });
        }

        @JavascriptInterface
        public void error(String message) {
            Log.d("JOGET_DOWNLOAD", "Blob download error: " + message);
            showError(message != null ? message : "Unknown error");
        }

        @JavascriptInterface
        public void download(String base64, String mimeType, String contentDisposition) {
            if (!isActive || base64 == null) {
                Log.d("JOGET_DOWNLOAD", "Download skipped - inactive or null base64");
                return;
            }

            try {
                Log.d("JOGET_DOWNLOAD", "Received base64 data, length: " + base64.length());

                String fileName = extractFileName(contentDisposition);
                if (fileName == null) {
                    fileName = InAppBrowserDownloads.this.generateFilename(mimeType);
                }

                // Remove data URI prefix if present
                String cleanBase64 = base64;
                if (base64.contains(",")) {
                    cleanBase64 = base64.substring(base64.indexOf(",") + 1);
                }

                byte[] bytes = android.util.Base64.decode(cleanBase64, android.util.Base64.DEFAULT);
                Log.d("JOGET_DOWNLOAD", "Decoded " + bytes.length + " bytes");

                InAppBrowserDownloads.this.saveFile(fileName, bytes, mimeType);

            } catch (Exception e) {
                Log.e("JOGET_DOWNLOAD", "Download failed", e);
                InAppBrowserDownloads.this.showError("Failed: " + e.getMessage());
            }
        }

        private String extractFileName(String cd) {
            if (cd == null) return null;
            try {
                if (cd.contains("filename=")) {
                    String filename = cd.substring(cd.indexOf("filename=") + 9);
                    filename = filename.replace("\"", "").trim();
                    if (filename.length() > 0) {
                        return filename;
                    }
                }
            } catch (Exception e) {
                Log.e("JOGET_DOWNLOAD", "Error extracting filename", e);
            }
            return null;
        }

        private void showToast(final String message) {
            plugin.cordova.getActivity().runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    Toast.makeText(plugin.cordova.getActivity().getApplicationContext(),
                            message, Toast.LENGTH_LONG).show();
                }
            });
        }
    }




    public void onDownloadStart(String url, String userAgent,
            String contentDisposition, String mimetype,
            long contentLength) {

        InAppBrowserDownloads.this.url = url;
        InAppBrowserDownloads.this.userAgent = userAgent;
        InAppBrowserDownloads.this.contentDisposition = contentDisposition;
        InAppBrowserDownloads.this.mimetype = mimetype;
        InAppBrowserDownloads.this.contentLength = contentLength;

        if (Build.VERSION.SDK_INT >= 23 && Build.VERSION.SDK_INT <= 30) {
            if (plugin.cordova.getActivity().checkSelfPermission(
                    android.Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED) {
                processDownload();
            } else {
                plugin.cordova.requestPermission(InAppBrowserDownloads.this.plugin, 0,
                        android.Manifest.permission.WRITE_EXTERNAL_STORAGE);
            }
        } else { // permission is automatically granted on sdk<23 upon installation
            processDownload();
        }
    }

    public void onRequestPermissionResult(int requestCode, String[] permissions,
            int[] grantResults) throws JSONException {
        for (int r : grantResults) {
            if (r == PackageManager.PERMISSION_DENIED) {
                Toast.makeText(plugin.cordova.getActivity().getApplicationContext(),
                        "Error downloading file, missing storage permissions", Toast.LENGTH_LONG).show();
                inAppWebView.evaluateJavascript("document.querySelector('.page-loader').style.display = 'none';", null);
            } else {
                InAppBrowserDownloads.this.processDownload();
            }
        }
    }

    protected void processDownload() {
        final String url = InAppBrowserDownloads.this.url;
        final String cookie = CookieManager.getInstance().getCookie(url);

        // Intercept blob URLs and data URIs to be handled separately from http/https download
        if (url == null || (!url.startsWith("http://") && !url.startsWith("https://"))) {
            handleNonHttpDownload(url);
            return;
        }

        String tempfilename = URLUtil.guessFileName(url, InAppBrowserDownloads.this.contentDisposition,
                InAppBrowserDownloads.this.mimetype);
        if (tempfilename.contains("; filename")) {
            tempfilename = tempfilename.substring(0, tempfilename.indexOf("; filename"));
        }
        final String filename = tempfilename;

        DownloadManager.Request request = new DownloadManager.Request(Uri.parse(url));
        plugin.cordova.getActivity().registerReceiver(attachmentDownloadCompleteReceive,
                new IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE), Context.RECEIVER_EXPORTED);

        try {
            request.allowScanningByMediaScanner();
            request.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED); // Notify
                                                                                                            // client
                                                                                                            // once
                                                                                                            // download
                                                                                                            // is
                                                                                                            // completed!
            request.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, filename);

            request.addRequestHeader("Cookie", cookie);
            request.addRequestHeader("User-Agent", InAppBrowserDownloads.this.userAgent);
            request.addRequestHeader("Referer", url);

            DownloadManager dm = (DownloadManager) plugin.cordova.getActivity().getSystemService(DOWNLOAD_SERVICE);
            dm.enqueue(request);

            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT); // This is important!
            intent.addCategory(Intent.CATEGORY_OPENABLE); // CATEGORY.OPENABLE
            intent.setType("*/*");// any application,any extension

            Toast.makeText(plugin.cordova.getActivity().getApplicationContext(), "Downloading file '" + filename + "'",
                    Toast.LENGTH_LONG).show();
            inAppWebView.evaluateJavascript("document.querySelector('.page-loader').style.display = 'none';", null);
        } catch (Exception exception) {
            Toast.makeText(plugin.cordova.getActivity().getApplicationContext(),
                    "Error downloading file, missing storage permissions", Toast.LENGTH_LONG).show();
            exception.printStackTrace();
            inAppWebView.evaluateJavascript("document.querySelector('.page-loader').style.display = 'none';", null);
        }
    }

    /**
     * From https://github.com/digistorm/cordova-plugin-inappbrowser/blob/master/src/android/InAppBrowserDownloads.java
     * Attachment download complete receiver.
     * <p/>
     * 1. Receiver gets called once attachment download completed.
     * 2. Open the downloaded file.
     */
    BroadcastReceiver attachmentDownloadCompleteReceive = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            String action = intent.getAction();
            if (DownloadManager.ACTION_DOWNLOAD_COMPLETE.equals(action)) {
                long downloadId = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, 0);
                openDownloadedAttachment(context, downloadId);
            }
        }
    };

    /**
     * Used to open the downloaded attachment.
     *
     * @param context    Content.
     * @param downloadId Id of the downloaded file to open.
     */
    private void openDownloadedAttachment(final Context context, final long downloadId) {
        DownloadManager downloadManager = (DownloadManager) context.getSystemService(Context.DOWNLOAD_SERVICE);
        DownloadManager.Query query = new DownloadManager.Query();
        query.setFilterById(downloadId);
        Cursor cursor = downloadManager.query(query);
        if (cursor.moveToFirst()) {
            int downloadStatus = cursor.getInt(cursor.getColumnIndex(DownloadManager.COLUMN_STATUS));
            String downloadLocalUri = cursor.getString(cursor.getColumnIndex(DownloadManager.COLUMN_LOCAL_URI));
            String downloadMimeType = cursor.getString(cursor.getColumnIndex(DownloadManager.COLUMN_MEDIA_TYPE));
            if ((downloadStatus == DownloadManager.STATUS_SUCCESSFUL) && downloadLocalUri != null) {
                openDownloadedAttachment(context, Uri.parse(downloadLocalUri), downloadMimeType);
            }
        }
        cursor.close();
    }

    /**
     * Used to open the downloaded attachment.
     * <p/>
     * 1. Fire intent to open download file using external application.
     *
     * 2. Note:
     * 2.a. We can't share fileUri directly to other application (because we will
     * get FileUriExposedException from Android7.0).
     * 2.b. Hence we can only share content uri with other application.
     * 2.c. We must have declared FileProvider in manifest.
     * 2.c. Refer -
     * https://developer.android.com/reference/android/support/v4/content/FileProvider.html
     *
     * @param context            Context.
     * @param attachmentUri      Uri of the downloaded attachment to be opened.
     * @param attachmentMimeType MimeType of the downloaded attachment.
     */
    private void openDownloadedAttachment(final Context context, Uri attachmentUri, final String attachmentMimeType) {
        if (attachmentUri != null) {
            try {
                // Get Content Uri.
                if (ContentResolver.SCHEME_FILE.equals(attachmentUri.getScheme())) {
                    // FileUri - Convert it to contentUri.
                    File file = new File(attachmentUri.getPath());
                    attachmentUri = FileProvider.getUriForFile(context, plugin.cordova.getActivity().getPackageName() + ".cdv.core.file.provider", file);
                }

                Intent openAttachmentIntent = new Intent(Intent.ACTION_VIEW);
                openAttachmentIntent.setDataAndType(attachmentUri, attachmentMimeType);
                openAttachmentIntent.setFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);

                context.startActivity(openAttachmentIntent);
                inAppWebView.evaluateJavascript("document.querySelector('.page-loader').style.display = 'none';", null);
            } catch (Exception e) {
                Toast.makeText(context, "Error opening downloaded file", Toast.LENGTH_LONG).show();
                e.printStackTrace();
            }
        }
    }


    /*
     * Methods used to handle file download from data URLs and blob URLs
     * 
     * 1. Interceptor intercepts the download request
     * 2. If the URL is a data URL or blob URL, it will be handled by handleDataUriDownload() or handleBlobUrlDownload() respectively
     * 3. If the URL is not a data URL or blob URL, it will be handled by the default download method
     * 4. For the blob, the JavaScript code will retrieve the blob from the store and convert it to a data URL which is then processed by the download() method
     * 5. For the data URL, it is processed directly by converting it to a file and then downloaded
     * 
     */


    // interceptor
    private void handleNonHttpDownload(String url) {
        if (url != null && url.startsWith("data:")) {
            handleDataUriDownload(url);
        } else if (url != null && url.startsWith("blob:")) {
            handleBlobUrlDownload(url);
        } else {
            // Show error for unsupported URL schemes
            showError("Unsupported download URL scheme: " + (url != null ? url.substring(0, Math.min(url.length(), 20)) + "..." : "null"));
        }
    }


   
    // Handles blob: URLs by retrieving the stored blob from __jogetBlobStore
     
    private void handleBlobUrlDownload(String blobUrl) {
        String safeMime = mimetype != null ? mimetype.replace("'", "\\'") : "";
        String safeCD = contentDisposition != null ? contentDisposition.replace("'", "\\'") : "";

        // JavaScript to retrieve the blob from the store and convert it
        String jsCode = "(function() {" +
                "  if (!window.__jogetBlobStore) {" +
                "    console.error('Blob store not available');" +
                "    if (window.CordovaBlobDownloader) {" +
                "      CordovaBlobDownloader.error('Blob store not available');" +
                "    }" +
                "    return 'no_blob_store';" +
                "  }" +
                "  " +
                "  var blobId = window.__jogetBlobStore['" + blobUrl + "'];" +
                "  " +
                "  if (blobId && window.__jogetBlobStore[blobId]) {" +
                "    var blob = window.__jogetBlobStore[blobId];" +
                "    " +
                "    var reader = new FileReader();" +
                "    reader.onloadend = function() {" +
                "      if (window.CordovaBlobDownloader) {" +
                "        console.log('Sending blob to Android');" +
                "        CordovaBlobDownloader.download(reader.result, '" + safeMime + "', '" + safeCD + "');" +
                "      } else {" +
                "        console.error('CordovaBlobDownloader not available');" +
                "      }" +
                "    };" +
                "    reader.onerror = function(error) {" +
                "      console.error('Blob conversion error:', error);" +
                "      if (window.CordovaBlobDownloader) {" +
                "        CordovaBlobDownloader.error('Blob conversion failed');" +
                "      }" +
                "    };" +
                "    reader.readAsDataURL(blob);" +
                "    return 'blob_found_and_converting';" +
                "  }" +
                "  " +
                "  console.log('Blob not found in store, trying fallback');" +
                "  var keys = Object.keys(window.__jogetBlobStore);" +
                "  var latestKey = keys.filter(function(k) { return k.startsWith('blob_'); }).sort().pop();" +
                "  " +
                "  if (latestKey && window.__jogetBlobStore[latestKey]) {" +
                "    console.log('Using fallback blob, key:', latestKey);" +
                "    var fallbackBlob = window.__jogetBlobStore[latestKey];" +
                "    " +
                "    var reader2 = new FileReader();" +
                "    reader2.onloadend = function() {" +
                "      console.log('Fallback blob converted, length:', reader2.result ? reader2.result.length : 0);" +
                "      if (window.CordovaBlobDownloader) {" +
                "        console.log('Sending fallback blob to Android');" +
                "        CordovaBlobDownloader.download(reader2.result, '" + safeMime + "', '" + safeCD + "');" +
                "      }" +
                "    };" +
                "    reader2.readAsDataURL(fallbackBlob);" +
                "    return 'fallback_blob_used';" +
                "  }" +
                "  " +
                "  console.error('No blob found in store');" +
                "  if (window.CordovaBlobDownloader) {" +
                "    CordovaBlobDownloader.error('No blob found in store');" +
                "  }" +
                "  return 'no_blob_found';" +
                "})();";

        Log.d("JOGET_DOWNLOAD", "Retrieving blob from store for URL: " + blobUrl);
        inAppWebView.evaluateJavascript(
            jsCode,
            new android.webkit.ValueCallback<String>() {
                @Override
                public void onReceiveValue(String value) {
                    Log.d("JOGET_DOWNLOAD", "Blob retrieval result: " + value);
                }
            }
        );
    }

    /**
     * Handles data: URIs by decoding and saving them as files
     */
    private void handleDataUriDownload(String dataUri) {
        try {
            Log.d("JOGET_DOWNLOAD", "handleDataUriDownload called");
            // Parse data URI: data:[<<mediatype>][;base64],<<data>>
            String[] parts = dataUri.split(",", 2);
            if (parts.length < 2) {
                showError("Invalid data URI format");
                return;
            }

            String header = parts[0];
            String data = parts[1];

            // Extract mime type and determine if base64
            String mimeType = "application/octet-stream";
            boolean isBase64 = header.contains(";base64");

            if (header.contains(":")) {
                String mimePart = header.substring(header.indexOf(":") + 1);
                if (mimePart.contains(";")) {
                    mimeType = mimePart.substring(0, mimePart.indexOf(";"));
                } else {
                    mimeType = mimePart;
                }
            }

            // Decode data
            byte[] fileData;
            if (isBase64) {
                fileData = android.util.Base64.decode(data, android.util.Base64.DEFAULT);
            } else {
                fileData = data.getBytes(StandardCharsets.UTF_8);
            }

            // Save using helper methods
            String filename = generateFilename(mimeType);
            saveFile(filename, fileData, mimeType);

        } catch (Exception e) {
            e.printStackTrace();
            showError("Error processing data URI: " + e.getMessage());
        }
    }

    /**
     * Helper method to generate filename from mime type
     */
    private String generateFilename(String mime) {
        String timestamp = String.valueOf(System.currentTimeMillis());
        String extension = getFileExtension(mime);
        return "download_" + timestamp + extension;
    }

    /**
     * Helper method to get file extension from mime type
     */
    private String getFileExtension(String mime) {
        if (mime == null) return ".bin";
        if (mime.contains("pdf")) return ".pdf";
        if (mime.contains("png")) return ".png";
        if (mime.contains("jpeg") || mime.contains("jpg")) return ".jpg";
        if (mime.contains("json")) return ".json";
        if (mime.contains("text")) return ".txt";
        return ".bin";
    }

    /**
     * Helper method to save file with proper Android version handling
     */
    private void saveFile(String name, byte[] bytes, String mime) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                saveFileQ(name, bytes, mime);
            } else {
                saveFileLegacy(name, bytes, mime);
            }
        } catch (Exception e) {
            Log.e("JOGET_DOWNLOAD", "Failed to save file", e);
            showError("Failed to save file: " + e.getMessage());
        }
    }

    /**
     * Save file for Android Q+ using MediaStore
     */
    private void saveFileQ(String name, byte[] bytes, String mime) {
        try {
            android.content.ContentValues values = new android.content.ContentValues();
            values.put(android.provider.MediaStore.Downloads.DISPLAY_NAME, name);
            values.put(android.provider.MediaStore.Downloads.MIME_TYPE, mime != null ? mime : "application/octet-stream");
            values.put(android.provider.MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS);

            android.content.ContentResolver resolver = plugin.cordova.getActivity().getContentResolver();
            android.net.Uri uri = resolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
            
            if (uri == null) {
                showError("Failed to create file in MediaStore");
                return;
            }

            java.io.OutputStream outputStream = resolver.openOutputStream(uri);
            if (outputStream != null) {
                outputStream.write(bytes);
                outputStream.close();
            }

            showToast(name + " downloaded");
            openDownloadedUri(uri, mime);

        } catch (Exception e) {
            Log.e("JOGET_DOWNLOAD", "Failed to save file on Android Q+", e);
            showError("Failed to save file: " + e.getMessage());
        }
    }

    /**
     * Save file for legacy Android using direct file access
     */
    private void saveFileLegacy(String name, byte[] bytes, String mime) {
        try {
            java.io.File downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
            java.io.File file = new java.io.File(downloadsDir, name);
            
            if (!downloadsDir.exists()) {
                downloadsDir.mkdirs();
            }

            java.io.FileOutputStream fos = new java.io.FileOutputStream(file);
            fos.write(bytes);
            fos.close();

            android.net.Uri uri = FileProvider.getUriForFile(
                plugin.cordova.getActivity(),
                plugin.cordova.getActivity().getPackageName() + ".cdv.core.file.provider",
                file
            );

            showToast(name + " downloaded");
            openDownloadedUri(uri, mime);

        } catch (Exception e) {
            Log.e("JOGET_DOWNLOAD", "Failed to save file on legacy Android", e);
            showError("Failed to save file: " + e.getMessage());
        }
    }

    /**
     * Open downloaded file URI
     */
    private void openDownloadedUri(android.net.Uri uri, String mime) {
        try {
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(uri, mime != null ? mime : "application/octet-stream");
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);

            if (intent.resolveActivity(plugin.cordova.getActivity().getPackageManager()) != null) {
                plugin.cordova.getActivity().startActivity(intent);
            } else {
                showError("No app found to open this file type");
            }
        } catch (Exception e) {
            Log.e("JOGET_DOWNLOAD", "Failed to open file", e);
            showError("Failed to open file: " + e.getMessage());
        } finally {
            // Hide loading indicator
            plugin.cordova.getActivity().runOnUiThread(() -> {
                inAppWebView.evaluateJavascript("document.querySelector('.page-loader').style.display = 'none';", null);
            });
        }
    }

    /**
     * Shows a toast message
     */
    private void showToast(String message) {
        plugin.cordova.getActivity().runOnUiThread(() -> {
            Toast.makeText(plugin.cordova.getActivity().getApplicationContext(),
                    message,
                    Toast.LENGTH_SHORT
                ).show();
        });
    }

    /**
     * Shows an error message and hides the loading indicator
     */
    private void showError(String message) {    
        plugin.cordova.getActivity().runOnUiThread(() -> {
            Toast.makeText(plugin.cordova.getActivity().getApplicationContext(),
                    message,
                    Toast.LENGTH_LONG
                ).show();

                inAppWebView.evaluateJavascript("document.querySelector('.page-loader').style.display = 'none';", null);
        });
    }


}
