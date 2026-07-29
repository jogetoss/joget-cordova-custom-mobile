
var MobileApp = {

    floatingButton: true,
    geolocation: false,
    homeUrl: null,

    init: function(homeUrl) {
        // device-specific initialization
        document.addEventListener("deviceready", MobileApp.initDevice, false);

        // reset login form validation 
        $(".is-invalid").removeClass("is-invalid");

        // hide profile management buttons
        $("#profile-buttons").hide();
        
        // load profiles
        var profileList = MobileApp.getProfileList();

        // check for specified home URL
        if (typeof homeUrl === "string" && homeUrl !== "") {
            MobileApp.homeUrl = homeUrl;
        }
        if (MobileApp.homeUrl && MobileApp.homeUrl !== "") {
            // hardcoded home URL specified, disable additional profiles
            var defaultProfile = "default";
            MobileApp.addProfile(defaultProfile);
            MobileApp.setHomeUrl(defaultProfile, MobileApp.homeUrl);
            MobileApp.loadProfile(defaultProfile);
            $("#profile").hide();
            $("#url").hide();
        } else if (profileList !== "") {
            // populate profile list
            var profiles = profileList.split(";");
            $("#profile").hide();
            $("#profile-container").empty();
            $("#profile-container").append("<select id=\"profile\" name=\"profile\" class=\"form-select\"></select><label for=\"profile\">Profile</label>");
            for (var i = 0; i < profiles.length; i++) {
                if (profiles[i] !== "") {
                    $("#profile").append("<option>"+profiles[i]+"</option>");
                }
            }

            // load profile on selection
            $("#profile").on("change", function() {
                var p = $("#profile").val();
                MobileApp.loadProfile(p);
            });

            // enable profile management buttons
            $("#profile-buttons").show();
            $("#profile-add").off("click");
            $("#profile-add").on("click", function() {
                 window.location.hash = "#newprofile";
                 MobileApp.newProfile();
            });
            $("#profile-delete").off("click");
            $("#profile-delete").on("click", function() {
                if (confirm("Delete this profile?")) {
                    MobileApp.deleteProfile();
                }
            });

            // load last profile
            var profile = MobileApp.getLastLogin();
            if (profileList !== "") {
                if (profiles.indexOf(profile) < 0) {
                    profile = profiles[0];
                    if (profile === "") {
                        profile = profiles[1];
                    }
                }
            } else {
                profile = "default";
            }
            $("#profile").val(profile).trigger("change");
            MobileApp.loadProfile(profile);

            // register device for push
            try {
                MobilePush.registerDevice();
            } catch(e) {
                console.log(e);
            }

        } else {
            // no existing profiles, create new one
            MobileApp.newProfile();
            $("#login-form #cancel").remove();
        }

        // handle back button
        $(document).on("backbutton", function(e) {
            if ($("#header:visible").length > 0) {
                e.preventDefault();
                navigator.app.exitApp();
            } else {
               navigator.app.backHistory();
            }
        });
    },

    initDevice: function() {
        // adjust UI for iOS status bar
        if (device && device.platform === "iOS") {
            $(document.body).addClass("ios");
            $("#main").addClass("ios");
            $("#header").addClass("ios");
        }
    },

    supportsHtml5Storage: function() {
        try {
            return 'localStorage' in window && window['localStorage'] !== null;
        } catch (e) {
            return false;
        }
    },

    getData: function(name) {
        var data;
        if (MobileApp.supportsHtml5Storage()) {
            data = localStorage.getItem(name);
        } else {
            data = $.cookie(name);
        }
        if (data == null) {
            data = "";
        }
        return data;
    },

    getProfileList: function() {
        return MobileApp.getData("profiles");
    },

    getLastLogin: function() {
        return MobileApp.getData("lastLogin");
    },

    getHomeUrl: function(profile) {
        return MobileApp.getData(profile + "_homeUrl");
    },

    getUsername: function(profile) {
        return MobileApp.getData(profile + "_username");
    },

    getPassword: function(profile) {
        return MobileApp.getData(profile + "_password");
    },

    getRememberPassword: function(profile) {
        return MobileApp.getData(profile + "_rememberPassword");
    },

    setData: function(name, value) {
        if (MobileApp.supportsHtml5Storage()) {
            localStorage.setItem(name, value);
        } else {
            $.cookie(name, value);
        }
    },

    setLastLogin: function(profile) {
        MobileApp.setData("lastLogin", profile);
    },

    setHomeUrl: function(profile, url) {
        MobileApp.setData(profile + "_homeUrl", url);
    },

    setUsername: function(profile, username) {
        MobileApp.setData(profile + "_username", username);
    },

    setPassword: function(profile, password) {
        MobileApp.setData(profile + "_password", password);
    },

    setRememberPassword: function(profile, rememberPassword) {
        MobileApp.setData(profile + "_rememberPassword", rememberPassword);
    },

    getFullUrl: function(url) {
        if (!url || url === "") {
            return "";
        }

        //remove extra "/" at the end of the url
        if (url.match(/\/$/)) {
            url = url.substring(0, url.length - 1);
        }

        //if no http/https, add http
        if (!url.toLowerCase().match(/(http|https):\/\/.*$/)) {
            url = "https://" + url;
        }

        var fullUrl;

        //if url is userview or mobile direct link
        if (url.indexOf("/web/userview/") > 0 || url.indexOf("/web/mobile/") > 0) {
            fullUrl = url;
        } else {
            fullUrl = url

            // if without context path, add /jw
            if (!url.toLowerCase().match(/(http|https):\/\/.*\/.*$/)) {
                fullUrl = fullUrl + "/jw";
            }

            var loginPath = "/web/mobile";
            fullUrl = fullUrl + loginPath;
        }
        return fullUrl;
    },

    addProfile: function(profile) {
        var profileList = MobileApp.getProfileList();
        var profiles = profileList.split(";");
        for (var i=0; i<profiles.length; i++) {
            if (profiles[i].toLowerCase() === profile.toLowerCase()) {
                profiles.splice(i, 1);
                break;
            }
        }
        profiles.push(profile);
        profileList = profiles.join(";");
        MobileApp.setData("profiles", profileList);
    },

    deleteProfile: function() {
        var profile = $("#profile").val();

        var profileList = MobileApp.getProfileList();
        var profiles = profileList.split(";");
        for (var i=0; i<profiles.length; i++) {
            if (profiles[i].toLowerCase() === profile.toLowerCase()) {
                profiles.splice(i, 1);
                break;
            }
        }
        profileList = profiles.join(";");
        MobileApp.setData("profiles", profileList);

        $("#profile-container").html("");
        $("#profile-buttons").hide();
        try {
            MobilePush.unregisterDevice(profile);
        } catch(e) {
            console.log(e);
        }
        MobileApp.init();
    },

    newProfile: function() {
        $("#profile-container").html("");
        $("#profile-buttons").hide();        
        $("#profile").show();

        if ($("#login-form #cancel").length == 0) {
            $("#form-buttons").append('<button id="cancel" name="cancel" class="btn btn-secondary">Cancel</button>');
            $("#login-form #cancel").on("click", function() {
                $(this).remove();
                MobileApp.init();
            });
        }

        MobileApp.loadProfile("");
        $("#profile").focus();
    },

    loadProfile: function(profile) {
        var homeUrl = (profile === "") ? "" : MobileApp.getHomeUrl(profile);
        var username = (profile === "") ? "" : MobileApp.getUsername(profile);
        var password = (profile === "") ? "" : MobileApp.getPassword(profile);
        var rememberPassword = (profile === "") ? "" : MobileApp.getRememberPassword(profile);

        $("#profile").val(profile);
        $("#url").val(homeUrl);
        $("#username").val(username);
        $("#password").val(password);
        if (rememberPassword == "true") {
            $("#rememberPassword").prop('checked', true);
        }
        if (!homeUrl || homeUrl == '') {
            $("#url").val("");
            $("#url").focus();
        } else if (!username || username == '') {
            $("#username").focus();
        } else if (!password || password == '') {
            $("#password").focus();
        } else {
            $("#login").focus();
        }
    },

    loginBiometric: function() {
        if (typeof Fingerprint !== "undefined") {
            // biometric plugin available (https://github.com/niklasmerz/cordova-plugin-fingerprint-aio), supports Fingerprint and Face ID)
            Fingerprint.isAvailable(isAvailableSuccess, isAvailableError);
                function isAvailableSuccess(result) {
                    console.log("loginWithBiometric: " + result + " available");

                    // authenticate using biometric
                    Fingerprint.show({ description: "Secure Login" }, successCallback, errorCallback);
                        function successCallback() {
                            console.log("loginWithBiometric: Authentication successful");
                            MobileApp.login();
                        }
                        function errorCallback(error) {
                            console.log("loginWithBiometric: " + error.message);
                        }
                }    
                function isAvailableError(error) {
                    // biometric not available, use default login
                    console.log("loginWithBiometric error: " + error);
                    MobileApp.login();
                }
        } else {
            // biometric not available, use default login
            MobileApp.login();
        }
        return false;
    },

    login: function() {
        var profile = $("#profile").val().trim();
        var url = $("#url").val().trim();
        var username = $("#username").val().trim();
        var password = $("#password").val();
        var rememberPassword = $("#rememberPassword:checked").val();

        $(".required").remove();
        if (profile === "") {
            $("#profile").addClass("is-invalid");
        }
        if (url === "") {
            $("#url").addClass("is-invalid");
        }
        if (username === "") {
            $("#username").addClass("is-invalid");
        }
        if (password === "") {
            $("#password").addClass("is-invalid");
        }

        if (profile && profile != "" && url && url != "" && username && username != "" && password && password != "") {
            MobileApp.showLoading();

            var fullUrl = MobileApp.getFullUrl(url);
            try {
                var urlParser = document.createElement("a");
                urlParser.href = fullUrl;
                var pathName = urlParser.pathname;
                var idx = pathName.substring(1, pathName.length).indexOf("/");
                if (idx > 0) {
                    var success = false;
                    var contextPath = pathName.substring(1, idx + 1);
                    var apiUrl = urlParser.protocol + "//" + urlParser.host + "/" + contextPath + "/web/mapp/xxx/xxx";
                    $.support.cors = true;
                    try {
                        $.ajax({
                            type: 'GET',
                            url: apiUrl,
                            dataType: "json",
                            error: function (data) {
                                if (data.status === 401 || data.status === 404) {
                                    success = true;
                                    if ($("#profile").length > 0) {
                                        MobileApp.addProfile(profile);
                                    }

                                    MobileApp.setLastLogin(profile);
                                    MobileApp.setHomeUrl(profile, url);
                                    MobileApp.setUsername(profile, username);
                                    if (rememberPassword == "true") {
                                        MobileApp.setPassword(profile, password);
                                    } else {
                                        MobileApp.setPassword(profile, "");
                                    }
                                    MobileApp.setRememberPassword(profile, rememberPassword);

                                    MobilePush.registerDevice();
                                    MobileApp.loginAndNavigate(fullUrl, username, password);

                                    MobileApp.init();

                                } else {
                                    MobileApp.hideLoading();
                                    alert("Invalid Server or Unsupported Version");
                                }
                            }
                        });
                    } catch (e) {
                    }
                    setTimeout(function () {
                        MobileApp.hideLoading();
                    }, 30000);
                } else {
                    MobileApp.hideLoading();
                    alert("Invalid URL " + fullUrl);
                }
            } catch (e) {
                MobileApp.hideLoading();
                alert("Invalid URL: " + fullUrl);
            }
            return false;
        } else {
            return false;
        }
    },

    navigate: function(url) {
        MobileApp.showLoading();

        var login = false;

        // check for matching profile
        var parser = document.createElement('a');
        parser.href = url;
        var hostUri = "http://" + parser.host + "/";
        console.log("host: " + parser.host);
        var hostUriHttps = "https://" + parser.host + "/";
        var profileList = MobileApp.getProfileList();
        var profiles = profileList.split(";");
        for (var i = 0; i < profiles.length; i++) {
            var profile = profiles[i];
            var rememberPassword = MobileApp.getRememberPassword(profile);
            if (rememberPassword === "true") {
                console.log("checking profile: " + profile);
                var domain = MobileApp.getFullUrl(MobileApp.getHomeUrl(profile));
                if (domain.indexOf(hostUri) === 0 || domain.indexOf(hostUriHttps) === 0) {
                    // matching profile with remember password found
                    console.log("matching profile: " + profile);
                    var username = MobileApp.getUsername(profile);
                    var password = MobileApp.getPassword(profile);
                    // login and navigate to URL
                    MobileApp.loginAndNavigate(url, username, password);
                    login = true;
                    break;
                }
            }
        }

        if (!login) {
            // show URL in frame
            MobileApp.showFrame(url);
        }
    },

    loginAndNavigate: function(url, username, password) {
        var parser = document.createElement('a');
        parser.href = url;
        var hostUri = parser.protocol + "//" + parser.host;
        var search = parser.search;
        var loginUrl = hostUri + "/jw/j_spring_security_check";    
        var credentials = "j_username=" + encodeURIComponent(username) + "&j_password=" + encodeURIComponent(password);
        var newUrl = url;
        if (newUrl.indexOf("/web/userview/") > 0) {
            newUrl = newUrl.replace('userview','ulogin');
        } else {
            newUrl += (search) ? "&" : "?";
            newUrl += "_cordova=true";
        }
        MobileApp.showFrame(newUrl, loginUrl, credentials, username, password);
    },

    showFrame: function(url, loginUrl, credentials, username, password) {
        // implementation using InAppBrowser plugin https://cordova.apache.org/docs/en/latest/reference/cordova-plugin-inappbrowser/
        // use InAppBrowser.executeScript method because session cookies are not passed over to the webview
        var inAppBrowser = (typeof cordova !== "undefined") ? cordova.InAppBrowser : window;
        var ios = typeof device !== "undefined" && device.platform === "iOS";
        var showLocationBar = (MobileApp.floatingButton && !ios) ? "no" : "yes"; // location bar should always be shown in iOS so that back navigation buttons are available e.g. when viewing images/documents
        MobileApp.inAppBrowser = inAppBrowser.open(url, "_blank", "clearcache=yes,clearsessioncache=yes,hidden=yes,location=" + showLocationBar + ",toolbar=" + showLocationBar + ",toolbarcolor=#000000,navigationbuttoncolor=#ffffff,closebuttoncolor=#ffffff,closebuttoncaption=X,toolbartranslucent=no,toolbarposition=bottom,hideurlbar=yes,zoom=no");
        if (loginUrl) {
            // perform login
            var callback = function () {
                var loginScript = " \
                    try { \
                        var xhttp = new XMLHttpRequest(); \
                        xhttp.onreadystatechange = function() { \
                            if (this.readyState == 4) { \
                                console.log('login done'); \
                                var redirectURL = '" + url + "'; \
                                var parser = new DOMParser(); \
                                var responseHTML = parser.parseFromString(this.responseText, 'text/html'); \
                                var loginForm = responseHTML.querySelector('form#loginForm'); \
                                if (loginForm && document.querySelector('form#loginForm')) { \
                                    redirectURL = '';  \
                                    document.getElementById('j_username').value = '" + username + "'; \
                                    document.getElementById('j_password').value = '" + password + "'; \
                                    var loginButton = document.querySelector('body#login #loginForm table td input[type=\"submit\"]'); \
                                    if (loginButton) { \
                                        loginButton.click(); \
                                    }\
                                } \
                                if (redirectURL) { \
                                    window.location.href = redirectURL; \
                                } \
                                var data = {'action': 'show', 'message': 'true'}; \
                                var json = JSON.stringify(data); \
                                window.onload=function(){webkit.messageHandlers.cordova_iab.postMessage(json);}; \
                            } \
                        }; \
                        xhttp.open('POST', '" + loginUrl + "', false); \
                        xhttp.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded'); \
                        console.log('logging in'); \
                        xhttp.send('" + credentials + "'); \
                        document.body.innerHTML = '<div style=\"margin-left:45%;margin-top:10%\"><img src=\"/jw/xadmin/lib/layui/css/modules/layer/default/loading-0.gif\"></div>'; \
                    } catch(e) { \
                        console.log(e); \
                    } ";
                if (MobileApp.inAppBrowser.executeScript) {
                    // InAppBrowser detected, use executeScript to insert code
                    try {
                        MobileApp.inAppBrowser.executeScript({code: loginScript});
                    } catch(e) {
                        console.log(e);
                    }
                } else {
                    // fallback to standard JS eval function
                    try {
                        MobileApp.inAppBrowser.eval(loginScript);
                        MobileApp.hideLoading();
                    } catch(e) {
                        console.log(e);
                    }
                }
                console.log("login: " + loginUrl);
                MobileApp.inAppBrowser.removeEventListener("loadstop", callback);
                MobileApp.inAppBrowser.removeEventListener("load", callback);
            };
            MobileApp.inAppBrowser.addEventListener("loadstop", callback);
            MobileApp.inAppBrowser.addEventListener("load", callback);
        }

        // insert custom JavaScript codes into the InAppBrowser window once it stops loading
        MobileApp.inAppBrowser.addEventListener("loadstop", function() {
            // show the InAppBrowser window
            MobileApp.hideLoading();
            MobileApp.inAppBrowser.show();

            // InAppBrowser message event listener
            MobileApp.inAppBrowser.addEventListener("message", function(params) {
                var action = params.data.action;
                var message = params.data.message;
                MobileApp.cordovaAction(action, message, params);                
            });

            // insert utility function cordovaAction into InAppBrowser
            MobileApp.inAppBrowser.executeScript({ code: "\
                var cordovaAction = function(action, message) { \
                    var data = {'action': action, 'message': message}; \
                    var json = JSON.stringify(data); \
                    webkit.messageHandlers.cordova_iab.postMessage(json); \
                } \
                "
            });
            console.log("Injected function cordovaAction");

            // update file download links to force attachment download and hide page loader overlay
            MobileApp.inAppBrowser.executeScript({ code: '\
                $(".form-fileupload a[target=_blank]").each(function(index, el) { \
                    var href = $(el).attr("href"); \
                    if (href.endsWith(".")) { \
                        href = href + "?attachment=true"; \
                    } \
                    $(el).attr("href", href); \
                    $(el).off("click"); \
                    $(el).on("click", function() {  \
                        setTimeout(function() { \
                            $(".page-loader").hide(); \
                        }, 2000); \
                    }); \
                }); \
            '
            });
            console.log("Updated file download links");

            if (MobileApp.floatingButton) {
                // insert floating button code into InAppBrowser
                MobileApp.inAppBrowser.executeScript({ code: "\
                    if ($('#floatingButton').length == 0) {\
                        $(document.body).append($(\"<div id='floatingButton'><i class='fa fa-power-off'></i></div>\"));	\
                    }\
                    $('#floatingButton').show(); \
                    $('#floatingButton').on('click', function() { \
                        cordovaAction('close'); \
                    }); \
                    "
                });
                console.log("Inserted floating button");

                // insert floating button CSS into InAppBrowser
                MobileApp.inAppBrowser.insertCSS({ code: "\
                    #floatingButton { \
                        z-index: 1000000; \
                        display: block; \
                        background: #607D8B; \
                        position: fixed; \
                        bottom: 10px; \
                        left: 10px; \
                        width: 38px; \
                        height: 38px; \
                        border-radius: 20px; \
                        opacity: 0.8; \
                        color: white; \
                        text-align: center; \
                        font-size: 28px; \
                        box-shadow: 1px 1px 1px #555; \
                        pointer: cursor; \
                    } \
                    #adminControl { \
                        display: none !important; \
                    } \
                    "
                });
                console.log("Inserted floating button CSS");
            }
        });

        // init geolocation permission
        if (navigator.geolocation) {
            MobileApp.requestLocationPermission(function(granted) {
                if (granted) {
                    navigator.geolocation.getCurrentPosition(function(position) { console.log(position) });
                    console.log("Geolocation initialized");
                } else {
                    console.log("Geolocation permission denied");
                }
            });
        }
    },

    closeFrame: function() {
        $("#main").fadeIn();
        MobileApp.inAppBrowser.close();
    },

    popup: function(title, message, url) {
        if (MobileApp.inAppBrowser) {
            try {
                MobileApp.inAppBrowser.hide();
            } catch(e) {
                console.log(e);
            }
        }
        $("#popup-dialog h4").text(title);
        $("#popup-dialog p").text(message);
        $("#popup-buttons").empty();
        if (url) {
            var navButton = $('<button class="btn btn-primary" data-bs-dismiss="modal">Go</button>');
            navButton.on("click", function() {
                $("#popup-dialog").modal("hide");
                MobileApp.navigate(url);
            });
            $("#popup-buttons").append(navButton);
            var cancelButton = $('<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button>');
            cancelButton.on("click", function() {
                $("#popup-dialog").modal("hide");
                MobileApp.inAppBrowser.show();
            });
            $("#popup-buttons").append(cancelButton);
        } else {
            var okButton = $('<button class="btn btn-primary" data-bs-dismiss="modal">OK</button>');
            okButton.on("click", function() {
                $("#popup-dialog").modal("hide");
                MobileApp.inAppBrowser.show();
            });
            $("#popup-buttons").append(okButton);
        }
        $("#popup-dialog").modal("show");
    },

    showLoading: function() {
        $("#loading").show();
        $("#loading").addClass("d-flex");
    },

    hideLoading: function() {
        $("#loading").hide();
        $("#loading").removeClass("d-flex");
    },

    requestLocationPermission: function(callback) {
        console.log("requestLocationPermission called");
        if (typeof cordova !== "undefined" && cordova.plugins && cordova.plugins.permissions) {
            var permissions = cordova.plugins.permissions;
            console.log("cordova.plugins.permissions available");
            permissions.checkPermission(permissions.ACCESS_FINE_LOCATION, function(status) {
                console.log("Permission check status: " + status.hasPermission);
                if (status.hasPermission) {
                    console.log("Permission already granted");
                    callback(true);
                } else {
                    console.log("Requesting permission...");
                    permissions.requestPermission(permissions.ACCESS_FINE_LOCATION, function(status) {
                        console.log("Permission request status: " + status.hasPermission);
                        if (status.hasPermission) {
                            callback(true);
                        } else {
                            callback(false);
                        }
                    }, function(error) {
                        console.log("Location permission request error: " + error);
                        callback(false);
                    });
                }
            }, function(error) {
                console.log("Location permission check error: " + error);
                callback(false);
            });
        } else {
            console.log("cordova.plugins.permissions not available, proceeding without permission request");
            callback(true);
        }
    },

    cordovaAction: function(action, message, params) {
        console.log("action: " + params.data.action);
        if (action === "close") {
            MobileApp.inAppBrowser.close();
        } else if (action === "geolocation") {
            MobileApp.requestLocationPermission(function(granted) {
                if (granted) {
                    navigator.geolocation.getCurrentPosition(function(position) { 
                        console.log(position) 
                    });
                } else {
                    console.log("Geolocation permission denied");
                } 
            });
        } else if (action === "vibration") {
            navigator.vibrate(1000);
        } else if (action === "url") {
            var url = message;
            MobileApp.showFrame(url);
        } else if (action === "popup") {
            MobileApp.popup(message);
        } else if (action === "alert") {
            var message = params.data.message;
            navigator.notification.alert(message);
        } else {
            MobileApp.inAppBrowser.show();
        }
    },
}
$(function() {
    MobileApp.init();
});