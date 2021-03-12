//
//  OpenHaystack – Tracking personal Bluetooth devices via Apple's Find My network
//
//  Copyright © 2021 Secure Mobile Networking Lab (SEEMOO)
//  Copyright © 2021 The Open Wireless Link Project
//
//  SPDX-License-Identifier: AGPL-3.0-only
//

import MapKit
import OSLog
import SwiftUI

struct OpenHaystackMainView: View {

    @State var loading = false
    @EnvironmentObject var accessoryController: AccessoryController
 
    var accessories: [Accessory] {
        return self.accessoryController.accessories
    }

    @State var alertType: AlertType?
    @State var popUpAlertType: PopUpAlertType?
    @State var errorDescription: String?
    @State var searchPartyToken: String = ""
    @State var searchPartyTokenLoaded = false
    @State var mapType: MKMapType = .standard
    @State var isLoading = false
    @State var focusedAccessory: Accessory?
    @State var accessoryToDeploy: Accessory?
    
    @State var mailPluginIsActive = false
    
    @State var showESP32DeploySheet = false

    var body: some View {

        NavigationView {

            ManageAccessoriesView(
                alertType: self.$alertType,
                focusedAccessory: self.$focusedAccessory,
                accessoryToDeploy: self.$accessoryToDeploy,
                showESP32DeploySheet: self.$showESP32DeploySheet,
                mailPluginIsActive: self.mailPluginIsActive
            )
            .frame(minWidth: 280, idealWidth: 280, maxWidth: .infinity, minHeight: 300, idealHeight: 400, maxHeight: .infinity, alignment: .center)

            ZStack {
                AccessoryMapView(accessoryController: self.accessoryController, mapType: self.$mapType, focusedAccessory: self.focusedAccessory)
                    .overlay(self.mapOverlay)
                if self.popUpAlertType != nil {
                    VStack {
                        Spacer()
                        PopUpAlertView(alertType: self.popUpAlertType!)
                            .transition(AnyTransition.move(edge: .bottom))
                            .padding(.bottom, 30)
                    }
                }
            }
            .frame(minWidth: 500, idealWidth: 500, maxWidth: .infinity, minHeight: 300, idealHeight: 400, maxHeight: .infinity, alignment: .center)
            .toolbar(content: {
                Picker("", selection: self.$mapType) {
                    Text("Satellite").tag(MKMapType.hybrid)
                    Text("Standard").tag(MKMapType.standard)
                }
                .pickerStyle(SegmentedPickerStyle())
                Button(action: self.downloadLocationReports) {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(self.accessories.isEmpty)
            })
            .alert(
                item: self.$alertType,
                content: { alertType in
                    return self.alert(for: alertType)
                }
            )
            .onChange(of: self.searchPartyToken) { (searchPartyToken) in
                guard !searchPartyToken.isEmpty, self.accessories.isEmpty == false else { return }
                self.downloadLocationReports()
            }
            .onChange(
                of: self.popUpAlertType,
                perform: { popUpAlert in
                    guard popUpAlert != nil else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.popUpAlertType = nil
                    }
                }
            )
            .onAppear {
                self.onAppear()
            }
        }
        .navigationTitle(self.focusedAccessory?.name ?? "Your accessories")

    }

    // MARK: Subviews

    /// Overlay for the map that is gray and shows an activity indicator when loading.
    var mapOverlay: some View {
        ZStack {
            if self.isLoading {
                Rectangle()
                    .fill(Color.gray)
                    .opacity(0.5)

                ActivityIndicator(size: .large)
            }
        }
    }

    func onAppear() {

        /// Checks if the search party token can be fetched without the Mail Plugin. If true the plugin is not needed for this environment. (e.g.  when SIP is disabled)
        let reportsFetcher = ReportsFetcher()
        if let token = reportsFetcher.fetchSearchpartyToken(),
            let tokenString = String(data: token, encoding: .ascii)
        {
            self.searchPartyToken = tokenString
            return
        }

        let pluginManager = MailPluginManager()

        // Check if the plugin is installed
        if pluginManager.isMailPluginInstalled == false {
            // Install the mail plugin
            self.alertType = .activatePlugin
        } else {
            self.checkPluginIsRunning(nil)
        }
    }

    /// Download the location reports for all current accessories. Shows an error if something fails, like plug-in is missing
    func downloadLocationReports() {
        self.accessoryController.downloadLocationReports { result in
            switch result {
            case .failure(let alert):
                if alert == .noReportsFound {
                    self.popUpAlertType = .noReportsFound
                }else {
                    self.alertType = alert
                }
            case .success(_):
                break
            }
        }
    }

    func deploy(accessory: Accessory) {
        self.accessoryToDeploy = accessory
        self.alertType = .selectDepoyTarget
    }

    /// Deploy the public key of the accessory to a BBC microbit.
    func deployAccessoryToMicrobit(accessory: Accessory) {
        do {
            try MicrobitController.deploy(accessory: accessory)
        } catch {
            os_log("Error occurred %@", String(describing: error))
            self.alertType = .deployFailed
            return
        }

        self.alertType = .deployedSuccessfully

        self.accessoryToDeploy = nil
    }

    /// Ask to install and activate the mail plugin.
    func installMailPlugin() {
        let pluginManager = MailPluginManager()
        guard pluginManager.isMailPluginInstalled == false else {

            return
        }
        do {
            try pluginManager.installMailPlugin()
        } catch {
            DispatchQueue.main.async {
                self.alertType = .pluginInstallFailed
                os_log(.error, "Could not install mail plugin\n %@", String(describing: error))
            }
        }
    }

    func checkPluginIsRunning(silent: Bool=false, _ completion: ((Bool) -> Void)?) {
        // Check if Mail plugin is active
        AnisetteDataManager.shared.requestAnisetteData { (result) in
            DispatchQueue.main.async {
                switch result {
                case .success(let accountData):

                    withAnimation {
                        if let token  = accountData.searchPartyToken {
                            self.searchPartyToken = String(data: token, encoding: .ascii) ?? ""
                            if self.searchPartyToken.isEmpty == false {
                                self.searchPartyTokenLoaded = true
                            }
                        }
                    }
                    self.mailPluginIsActive = true
                    completion?(true)
                case .failure(let error):
                    if let error = error as? AnisetteDataError, silent == false {
                        switch error {
                        case .pluginNotFound:
                            self.alertType = .activatePlugin
                        default:
                            self.alertType = .activatePlugin
                        }
                    }
                    self.mailPluginIsActive = false
                    completion?(false)
                    
                    //Check again in 5s
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: {
                        self.checkPluginIsRunning(silent: true, nil)
                    })
                }
            }
        }
    }

    func downloadPlugin() {
        do {
            try MailPluginManager().pluginDownload()
        } catch {
            self.alertType = .pluginInstallFailed
        }
    }

    // MARK: - Alerts

    // swiftlint:disable function_body_length
    /// Create an alert for the given alert type.
    ///
    /// - Parameter alertType: current alert type
    /// - Returns: A SwiftUI Alert
    func alert(for alertType: AlertType) -> Alert {
        switch alertType {
        case .keyError:
            return Alert(title: Text("Could not create accessory"), message: Text(String(describing: self.errorDescription)), dismissButton: Alert.Button.cancel())
        case .searchPartyToken:
            return Alert(
                title: Text("Add the search party token"),
                message: Text(
                    """
                    Please paste the search party token below after copying itfrom the macOS Keychain.
                    The item that contains the key can be found by searching for:
                    com.apple.account.DeviceLocator.search-party-token
                    """
                ),
                dismissButton: Alert.Button.okay())
        case .deployFailed:
            return Alert(
                title: Text("Could not deploy"),
                message: Text("Deploying to microbit failed. Please reconnect the device over USB"),
                dismissButton: Alert.Button.okay())
        case .deployedSuccessfully:
            return Alert(
                title: Text("Deploy successfull"),
                message: Text("This device will now be tracked by all iPhones and you can use this app to find its last reported location"),
                dismissButton: Alert.Button.okay())
        case .deletionFailed:
            return Alert(title: Text("Could not delete accessory"), dismissButton: Alert.Button.okay())

        case .noReportsFound:
            return Alert(
                title: Text("No reports found"),
                message: Text("Your accessory might have not been found yet or it is not powered. Make sure it has enough power to be found by nearby iPhones"),
                dismissButton: Alert.Button.okay())
        case .activatePlugin:
            let message =
                """
                To access your Apple ID for downloading location reports we need to use a plugin in Apple Mail.
                Please make sure Apple Mail is running.
                Open Mail -> Preferences -> General -> Manage Plug-Ins... -> Select Haystack

                We do not access any of your e-mail data. This is just necessary, because Apple blocks access to certain iCloud tokens otherwise.
                """

            return Alert(
                title: Text("Install & Activate Mail Plugin"), message: Text(message),
                primaryButton: .default(Text("Okay"), action: { self.installMailPlugin() }),
                secondaryButton: .cancel())

        case .pluginInstallFailed:
            return Alert(
                title: Text("Mail Plugin installation failed"),
                message: Text(
                    "To access the location reports of your devices an Apple Mail plugin is necessary"
                        + "\nThe installtion of this plugin has failed.\n\n Please download it manually unzip it and move it to /Library/Mail/Bundles"),
                primaryButton: .default(
                    Text("Download plug-in"),
                    action: {
                        self.downloadPlugin()
                    }), secondaryButton: .cancel())
        case .selectDepoyTarget:
            let microbitButton = Alert.Button.default(Text("Microbit"), action: { self.deployAccessoryToMicrobit(accessory: self.accessoryToDeploy!) })

            let esp32Button = Alert.Button.default(
                Text("ESP32"),
                action: {
                    self.showESP32DeploySheet = true
                })

            return Alert(
                title: Text("Select target"),
                message: Text("Please select to which device you want to deploy"),
                primaryButton: microbitButton,
                secondaryButton: esp32Button)
        case .downloadingReportsFailed:
            return Alert(title: Text("Downloading locations failed"),
                         message: Text("We could not download any locations from Apple. Please try again later"),
                         dismissButton: Alert.Button.okay())
        }
    }

    enum AlertType: Int, Identifiable, Error {
        var id: Int {
            return self.rawValue
        }

        case keyError
        case searchPartyToken
        case deployFailed
        case deployedSuccessfully
        case deletionFailed
        case noReportsFound
        case downloadingReportsFailed
        case activatePlugin
        case pluginInstallFailed
        case selectDepoyTarget
    }

}

struct OpenHaystackMainView_Previews: PreviewProvider {
    static var accessoryController = AccessoryControllerPreview(accessories: PreviewData.accessories, findMyController: FindMyController()) as AccessoryController

    static var previews: some View {
        OpenHaystackMainView()
            .environmentObject(self.accessoryController)
    }
}

extension Alert.Button {
    static func okay() -> Alert.Button {
        Alert.Button.default(Text("Okay"))
    }
}
