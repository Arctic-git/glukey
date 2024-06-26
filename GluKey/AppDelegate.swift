//
//  AppDelegate.swift
//  GluKey
//
//  Created by James Pierce on 5/26/17.
//  Copyright © 2017 James Pierce. All rights reserved.
//

import Cocoa
import Foundation
import Alamofire

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    // Initialize vars
    let notification            = NSUserNotification()
    let statusItem              = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let settingsStoryboard      = NSStoryboard.init(name: "Main", bundle: nil)
    var settingsWindowController: NSWindowController!
    var timer:Timer             = Timer.init()
    var timerInterval:Double    = 60
    
    // Initialize event monitors
    var monitorClick : EventMonitor?
    

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(AppDelegate.wakeUpListener), name: NSWorkspace.didWakeNotification, object: nil)
        
        // -----------------------------
        // Register UserDefaults
        // -----------------------------
        //
        UserDefaults.standard.register(defaults: [
            "useMmol"       : Constants.useMmolDefault,
            "dexcomUsername": "", // this will fail gracefully
            ])
        
        // -----------------------------
        // Launch settings if...
        // -----------------------------
        // Dexcom username || password is blank
        //
        let keychain = KeychainSwift()
        if UserDefaults.standard.string(forKey: "dexcomUsername") == "" || keychain.get("GluKey Password") == nil {
            settingsWindowController = (settingsStoryboard.instantiateController(withIdentifier: "Settings") as! NSWindowController)
            settingsWindowController.window?.makeKeyAndOrderFront(nil)
        }
        
        
        // -----------------------------
        // Default StatusItem Settings
        // -----------------------------
        // StatusItem icon
        //
        let iconBase = NSImage(named: Constants.statusIconBase)
        iconBase?.isTemplate = false // true should allow the arrow to invert but does not but it negatively affects the Glukey icon
        statusItem.image = iconBase
        
        
        // StatusItem icon
        //
        statusItem.title = "---"
        
        
        // StatusItem as button
        //
        if let button = statusItem.button {
            button.action = #selector(AppDelegate.togglePopover(_:))
            button.sendAction(on: [.leftMouseDown])
        }
        
        
        // Define Popover
        //
        Constants.popover.contentViewController = GlucoseGraphController(nibName: "GlucoseGraphController", bundle: nil)
        Constants.popover.animates = false
    
        // Initial load of glucose data
        //
        loadGlucoseData()
        
        
        // Load glucose data on timer
        //
        startGlucoseTimer()

        
        // Define and start event monitors to close popover when clicking away
        //
        monitorClick = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [unowned self] event in
            if Constants.popover.isShown {
                self.closePopover(event)
            }
        }

        monitorClick?.start()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
    // Insert code here to tear down application
    }
    
    
    @objc func wakeUpListener() {
        print("Wake Up Listening")
        updateMenuBarValue()
        loadGlucoseData()
    }
    
    // -----------------------------
    // Timer Functions
    // -----------------------------
    // NOTE: The Timer functionality works but could be improved as code is nested within another function
    //
    // Timer works as follows:
    // `applicationDidFinishLaunching` runs `loadGlucoseData`:
    //
    // - if `loadGlucoseData` successfully returns data:
    //   The function will set self.timerInterval to 5m08s from the last value
    //   The function will reset also the timer, but the minimum returned value is conditional to several factors (see notes in function),
    //   which is useful if the function is called and no new data is returned
    //
    // - if `loadGlucoseData` fails to returns data for any reason (likely invalid credentials or no internet):
    //   the Timer will not be reset, but loops every 60 seconds. 
    //
    
    
    func startGlucoseTimer() {
        let date = Date().addingTimeInterval(self.timerInterval)
        timer = Timer.init(fire: date, interval: 60, repeats: true) { (_) in
            self.loadGlucoseData()
        }
        RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
    }
    
    func resetGlucoseTimer() {
        timer.invalidate()
        startGlucoseTimer()
    }
    
    
    
    // -----------------------------
    // Popover Functions
    // -----------------------------
    //
    @objc func togglePopover(_ sender: AnyObject?) {
        if Constants.popover.isShown {
            closePopover(sender)
        } else {
            showPopover(sender)
        }
    }
    func showPopover(_ sender: AnyObject?) {
        if let button = statusItem.button {
            Constants.popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
        }
    }
    func closePopover(_ sender: AnyObject?) {
        Constants.popover.performClose(sender)
    }
    
    
    // -----------------------------
    // Update Status Bar
    // -----------------------------
    //
    func updateMenuBarValue() {
        if Constants.glucoseData.isEmpty == false && GlucoseHelper.validGuloseReading() {
            let current_data = GlucoseHelper.currentGulcoseReading()
            
            let directions = ["", "↑↑", "↑", "↗", "→", "↘", "↓", "↓↓", "?", "-"]

            // set value
            // if using mmol/L format, then divide by 18 and use `format:"%.01f"`
            if UserDefaults.standard.bool(forKey: "useMmol") {
                self.statusItem.title = String(format:"%@ %.01f", directions[current_data["Trend"] as! Int], current_data["Value"] as! Double)
            } else {
                self.statusItem.title = String(format:"%@ %.f", directions[current_data["Trend"] as! Int], current_data["Value"] as! Double)
            }

            // set trend line
//            self.statusItem.image = NSImage(named: "\(Constants.statusIconBase)\(current_data["Trend"]!)")
            self.statusItem.image = NSImage()
        } else {
            // No Data or out-of-date
            self.statusItem.title = "---"
            self.statusItem.image = NSImage(named: Constants.statusIconBase)
        }
    }
    
    
    
    // -----------------------------
    // Load Remote Data
    // -----------------------------
    //
    func loadGlucoseData() {
        // Future home for other sources such as Nightscout
        getSessionIdFromDexcom()
    }
    
    
    // -----------------------------
    // Dexcom Functions
    // NOTE: Possibly move to DexcomHelper in future
    // -----------------------------
    
    // First get sessionID from Dexcom
    // NOTE: `getSessionIdFromDexcom` will loop through all Dexcom base URLs to find the correct account type.
    //        Since Alamofire is an asynchronous call, normal catching of errors will not work and therefore a failed request will
    //        recursively call this method until all base URLs have been tried before handling the error with a `dexcomSessionError`.
    //
    func getSessionIdFromDexcom() {
        let keychain    = KeychainSwift()
        let parameters  = [
            "accountId": UserDefaults.standard.string(forKey: "dexcomUsername"),
            "password": keychain.get("GluKey Password"),
            "applicationId":"d8665ade-9673-4e27-9ff6-92db4ce13d13"
        ]
        
        
        // Remember: Alamofire JSON requests are asynchronous and getSessionIdFromDexcom will not "know" the result of the request
        //
        AF.request(DexcomHelper.authenticateURL(), method: .post, parameters: parameters as Parameters, encoding: JSONEncoding.default).validate(statusCode: 200..<300).responseString{ response in
            switch response.result {
            case .success:
                // Set session ID
                DexcomHelper.sessionID = (response.value!).replacingOccurrences(of: "\"", with: "")
                
                // Confirming account will prevent a connection failure from cylcing through other accountIndex even though it previously worked
                // This is important if Dexcom servers temporarily stop responding but internet connection is still active.
                DexcomHelper.accountConfirmed = true
                
                // Clearing error message, hides error message box
                Constants.errorMessage = ""
                
                // Run next Dexcom step
                self.getGlucoseDataFromDexcom()
                
            default:
                // if fails to connect to Dexcom with valid internet connection and account type is not confirmed,
                // then try next locale URL(s) before error handling
                if Connectivity.isConnectedToInternet && !DexcomHelper.accountConfirmed && DexcomHelper.accountIndex < DexcomHelper.maxAccountIndex {
                    DexcomHelper.accountIndex += 1
                    self.getSessionIdFromDexcom()
                } else {
                    self.dexcomSessionError()
                }
            }
        }
    }

    
    // Handle Dexcom session error, including setting error message
    //
    func dexcomSessionError() {
        print("Could not get session ID")
        
        if Connectivity.isConnectedToInternet {
            print("Connected to internet")
            
            // If valid internet connection and account credientials where not previously verified
            // assume the username/password is incorrect. Stop timers and clear data.
            //
            if DexcomHelper.accountConfirmed == false {
                // Setting error message will hide chart when popover triggered
                Constants.errorMessage = "Could not login. Please check your username/password."
                
                // Stop loop timer to prevent Glukey to continue to attempt to login,
                // causing the account to be temporarily locked out by Dexcom for too many failed attempts
                self.timer.invalidate()
                
                // Clear old data
                Constants.glucoseData = [[String: Any]]()
            }
            
        } else {
            print("Not connected to internet")
            
            // If connected not connected to internet, show message only if there is no data to graph.
            // `updateMenuBarValue` will hide current value if data is old.
            //
            if Constants.glucoseData.isEmpty {
                Constants.errorMessage = "Your computer does not appear to be connected to the internet."
            }
        }
        
        // Update menu bar as it may be required to set the data as "old"
        self.updateMenuBarValue()
    }
    
    
    // Second get glucose data from Dexcom
    //
    func getGlucoseDataFromDexcom() {
        var newGlucoseData:      Array   = [[String: Any]]() // serves as temp cache
        var nextGlucoseInterval: Double  = Double.init()
        
        AF.request(DexcomHelper.glucoseValuesURL(), method: .post).validate(statusCode: 200..<300).responseJSON { response in
            // Response values
            // DT (date)
            // ST (date)
            // WT (date)
            // Trend (String)
            // Value (int/double)
            
            switch response.result {
            case .success(let value):
                
                // set responseValues from Dexcom
                let responseValues : NSArray = value as! NSArray
     
                // set default `lastValue`
                var lastValue : NSDictionary = ["Value":-1.0]
                
                // set lastValue to actual data if any data is returned from server
                if responseValues.count != 0 {
                    lastValue = responseValues[0] as! NSDictionary
                }
                
                
                // Dexcom G6 sensor/transmittor errors:
                // returns `1.0` when sensor is expired
                // returns `5.0` when sensor is in startup calibration
                // returns `10.0` when sensor is reporting a "temporary issue"
                // trend for all is 8
                //
                // TODO Use these values to provide alerts and description in popup
                // (could also estimate time remaining for calibration to finish)
                //
                
                switch lastValue["Value"] as! Double {
                case -1.0:
                    print("No data returned within range")
                    Constants.sensorExpired     = false
                    Constants.sensorCalibration = false
                    Constants.sensorIssue       = false
                    // possibly set Constant to store flag that no data was returned within range
                case 1.0:
                    print("Sensor expired")
                    Constants.sensorExpired     = true
                    Constants.sensorCalibration = false
                    Constants.sensorIssue       = false
                case 5.0:
                    print("Sensor is in startup mode")
                    Constants.sensorExpired     = false
                    Constants.sensorCalibration = true
                    Constants.sensorIssue       = false
                case 10.0:
                    // This is when the app reports temporary issue and to wait (up to) 3 hours
                    print("Temporary sensor issue")
                    Constants.sensorExpired     = false
                    Constants.sensorCalibration = false
                    Constants.sensorIssue       = true
                default:
                    Constants.sensorExpired     = false
                    Constants.sensorCalibration = false
                    Constants.sensorIssue       = false
                }
                
                
                for case let value as NSDictionary in responseValues {
                    var numericValue: Double = (value["Value"] as! Double)
                    let dateString  : String = (value["ST"] as! String).replacingOccurrences(of: "Date(", with: "").replacingOccurrences(of: ")", with: "")
                    let dateInt     : Double = Double(dateString)! / 1000
                    let trendString : String = (value["Trend"] as! String)
                    
                    let trendInt : Int = {
                       switch trendString {
                           case "DoubleUp": return 1
                           case "SingleUp": return 2
                           case "FortyFiveUp": return 3
                           case "Flat": return 4
                           case "FortyFiveDown": return 5
                           case "SingleDown": return 6
                           case "DoubleDown": return 7
                           default: return 0
                       }
                    }()
                    
                    //print("numericValue [\(numericValue)] dateString [\(dateString)] dateInt [\(dateInt)] trendString[\(trendString)] trendInt[\(trendInt)]")
                    
                    // Skip Dexcom G6 'sensor' values noted above
                    if numericValue > 10.0 {
                        if UserDefaults.standard.bool(forKey: "useMmol") {
                            numericValue = numericValue / 18.0
                        }
                        
                        newGlucoseData.append(["Value": numericValue, "Trend": trendInt, "DT": dateInt, "Date": NSDate(timeIntervalSince1970: dateInt)])
                    }
                }
                
                
                // Check to make sure request returned Glucose data (or else the block of code will fail) and show error if no data
                // NOTE: This block of code within the conditional could possibly be refactored or moved into another method for simplicity
                //
                if newGlucoseData.isEmpty == false {
                
                    // if valid, then replace temp data with "global" glucose data
                    //
                    Constants.glucoseData = newGlucoseData
                
                    // Set minimum nextGlucoseInterval valuefor Timer loop (to prevent excessive API calls)
                    //
                    let lastDate:Date = GlucoseHelper.currentGulcoseReading()["Date"] as! Date
                
                
                    // https://oleb.net/blog/2015/09/swift-ranges-and-intervals/
                    //
                    switch lastDate.timeIntervalSinceNow {
                    case -360.0 ... -300.0                   : nextGlucoseInterval = 10 // try again in 10 seconds if less than 1 minute "past due"
                    case -420.0 ... -360.0                   : nextGlucoseInterval = 20 // try again in 20 seconds if between 1 and 2 minutes "past due"
                    case Constants.oldDataSeconds ... -420.0 : nextGlucoseInterval = 30 // try again in 30 seconds if between 2 and 5 minutes "past due"
                    case Double(Int.min) ... Constants.oldDataSeconds :
                        // Display old data notification (if allowed)
                        NotificationHelper.oldData(notification: self.notification)
                        
                        // Set next interval
                        nextGlucoseInterval = 60
                    default:
                        // Check for high/low notifications here
                        NotificationHelper.checkLowHigh(notification: self.notification)
                        
                        // Set next interval
                        nextGlucoseInterval = 310.0 + (GlucoseHelper.currentGulcoseReading()["DT"] as! Double) -  Date.init().timeIntervalSince1970
                    }
                
                
                    // Set nextGlucoseInterval for Timer loop
                    //
                    self.timerInterval = nextGlucoseInterval
                    print( nextGlucoseInterval )
                    self.resetGlucoseTimer()
                    
                    
                    // Clearing error message, hides error message box
                    Constants.errorMessage = ""
                
                } else {
                    print("No recent data")
                    
                    // Setting error message will hide chart when popover triggered
                    Constants.errorMessage = "Glukey connected successfully to Dexcom, but there is no data to display."
                }
                
            default:
                print("No Valid Connection")
                // Setting error message will hide chart when popover triggered
                // NOTE: I'm not sure if this would be different than not getting the session ID.
                //       I'm not sure if this default conditional will ever be reached.
                Constants.errorMessage = "Glukey could not connect to Dexcom."
            }
            
            // Update menu bar regardless if data was downloaded
            self.updateMenuBarValue()
        }
        
    }
}

