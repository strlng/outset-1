//
//  main.swift
//  outset
//
//  Created by Bart Reardon on 1/12/2022.
//
// swift implementation of outset by Joseph Chilcote https://github.com/chilcote/outset

import Foundation
import ArgumentParser

let author = "Bart Reardon - Adapted from outset by Joseph Chilcote (chilcote@gmail.com) https://github.com/chilcote/outset"
let outsetVersion = "4.0 alpha"

// Set some Constants TODO: leave these as defaults but maybe make them configurable from a plist
let outset_dir = "/usr/local/outset/"
let boot_every_dir = outset_dir+"boot-every"
let boot_once_dir = outset_dir+"boot-once"
let login_every_dir = outset_dir+"login-every"
let login_once_dir = outset_dir+"login-once"
let login_privileged_every_dir = outset_dir+"login-privileged-every"
let login_privileged_once_dir = outset_dir+"login-privileged-once"
let on_demand_dir = outset_dir+"on-demand"
let share_dir = outset_dir+"share/"
let outset_preferences = share_dir+"com.chilcote.outset.plist"
let on_demand_trigger = "/private/tmp/.com.github.outset.ondemand.launchd"
let login_privileged_trigger = "/private/tmp/.com.github.outset.login-privileged.launchd"
let cleanup_trigger = "/private/tmp/.com.github.outset.cleanup.launchd"

// Set some variables
var debugMode : Bool = false
var loginwindow : Bool = true
var console_user : String = NSUserName() 
var network_wait : Bool = true
var network_timeout : Int = 180
var ignored_users : [String] = []
var override_login_once : [String: Date] = [String: Date]()
var continue_firstboot : Bool = true
var (log_file, run_once_plist) = set_run_once_params()
var prefs = load_outset_preferences()

@main
struct Outset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "outset",
        abstract: "This script automatically processes packages, profiles, and/or scripts at boot, on demand, and/or login.")
    
    @Flag(help: .hidden)
    var debug = false
    
    @Flag(help: "Used by launchd for scheduled runs at boot")
    var boot = false
    
    @Flag(help: "Used by launchd for scheduled runs at login")
    var login = false
    
    @Flag(help: "Used by launchd for scheduled privileged runs at login")
    var loginPrivileged = false
    
    @Flag(help: "Process scripts on demand")
    var onDemand = false
    
    @Flag(help: "Manually process scripts in login-every")
    var loginEvery = false
    
    @Flag(help: "Manually process scripts in login-once")
    var loginOnce = false
    
    @Flag(help: "Used by launchd to clean up on-demand dir")
    var cleanup = false
        
    @Option(help: ArgumentHelp("Add one or more users to ignored list", valueName: "username"))
    var addIgnoredUser : [String] = []
    
    @Option(help: ArgumentHelp("Remove one or more users from ignored list", valueName: "username"))
    var removeIgnoredUser : [String] = []
    
    @Option(help: ArgumentHelp("Add one or more scripts to override list", valueName: "script"), completion: .file())
    var addOveride : [String] = []
        
    @Option(help: ArgumentHelp("Remove one or more scripts from override list", valueName: "script"), completion: .file())
    var removeOveride : [String] = []
    
    @Flag(help: "Show version number")
    var version = false
    
    mutating func run() throws {
                
        if debug {
            debugMode = true
            version = true
            sys_report()
        }
        
        if boot {
            ensure_working_folders()
            if !check_file_exists(path: outset_preferences) {
                dump_outset_preferences(prefs: prefs)
            }
            
            if !list_folder(path: boot_once_dir).isEmpty {
                if network_wait {
                    loginwindow = false
                    disable_loginwindow()
                    continue_firstboot = wait_for_network(timeout: floor(Double(network_timeout) / 10))
                }
                if continue_firstboot {
                    sys_report()
                    process_items(boot_once_dir, delete_items: true)
                } else {
                    logger("Unable to connect to network. Skipping boot-once scripts...", status: "error")
                }
                if !loginwindow {
                    enable_loginwindow()
                }
            }
            
            if !list_folder(path: boot_every_dir).isEmpty {
                process_items(boot_every_dir)
            }
            
            logger("Boot processing complete")
        }
        
        if login {
            if !ignored_users.contains(console_user) {
                if !list_folder(path: login_once_dir).isEmpty {
                    process_items(login_once_dir, once: true, override: override_login_once)
                }
                if !list_folder(path: login_every_dir).isEmpty {
                    process_items(login_every_dir)
                }
                if !list_folder(path: login_privileged_once_dir).isEmpty || !list_folder(path: login_privileged_every_dir).isEmpty {
                    FileManager.default.createFile(atPath: login_privileged_trigger, contents: nil)
                }
            }
            
        }
        
        if loginPrivileged {
            if check_file_exists(path: login_privileged_trigger) {
                path_cleanup(pathname: login_privileged_trigger)
            }
            if !ignored_users.contains(console_user) {
                if !list_folder(path: login_privileged_once_dir).isEmpty {
                    process_items(login_privileged_once_dir, once: true, override: override_login_once)
                }
                if !list_folder(path: login_privileged_every_dir).isEmpty {
                    process_items(login_privileged_every_dir)
                }
            } else {
                logger("Skipping login scripts for user \(console_user)")
            }
        }
        
        if onDemand {
            if !list_folder(path: on_demand_dir).isEmpty {
                if !["root", "loginwindow"].contains(console_user) {
                    let current_user = NSUserName()
                    if console_user == current_user {
                        process_items(on_demand_dir)
                    } else {
                        logger("User \(current_user) is not the current console user. Skipping on-demand run.")
                    }
                } else {
                    logger("No current user session. Skipping on-demand run.")
                }
                FileManager.default.createFile(atPath: cleanup_trigger, contents: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if check_file_exists(path: cleanup_trigger) {
                        path_cleanup(pathname: cleanup_trigger)
                    }
                }
            }
        }
        
        if loginEvery {
            if !ignored_users.contains(console_user) {
                if !list_folder(path: login_every_dir).isEmpty {
                    process_items(login_every_dir)
                }
            }
        }
        
        if loginOnce {
            if !ignored_users.contains(console_user) {
                if !list_folder(path: login_once_dir).isEmpty {
                    process_items(login_once_dir, once: true)
                }
            }
        }
        
        if cleanup {
            logger("Cleaning up on-demand directory.")
            if check_file_exists(path: on_demand_trigger) {
                    path_cleanup(pathname: on_demand_trigger)
            }
            if !list_folder(path: on_demand_dir).isEmpty {
                path_cleanup(pathname: on_demand_dir)
            }
        }
        
        if !addIgnoredUser.isEmpty {
            ensure_root("add to ignored users")
            ensure_shared_folder()
            for username in addIgnoredUser {
                logger("Adding \(username) to ignored users list")
                prefs.ignored_users.append(username)
            }
            dump_outset_preferences(prefs: prefs)
        }
        
        if !removeIgnoredUser.isEmpty {
            ensure_root("remove ignored users")
            for username in removeIgnoredUser {
                if let index = prefs.ignored_users.firstIndex(of: username) {
                    prefs.ignored_users.remove(at: index)
                }
            }
            dump_outset_preferences(prefs: prefs)
        }
        
        if !addOveride.isEmpty {
            ensure_root("add scripts to override list")
            ensure_shared_folder()
            
            for overide in addOveride {
                logger("Adding \(overide) to overide list")
                //let value : [String:Date] = [overide:.now]
                prefs.override_login_once[overide] = Date()
            }
            dump_outset_preferences(prefs: prefs)
        }
        
        if !removeOveride.isEmpty {
            ensure_root("remove scripts to override list")
            for overide in removeOveride {
                prefs.override_login_once.removeValue(forKey: overide)
            }
            dump_outset_preferences(prefs: prefs)
        }
        
        if version {
            print(outsetVersion)
        }
    }
}

