//
//  ContactDetails.swift
//  Monal
//
//  Created by Jan on 22.10.21.
//  Copyright © 2021 Monal.im. All rights reserved.
//

struct ContactDetails: View {
    var delegate: SheetDismisserProtocol
    private var account: xmpp
    @State private var ownRole = kMucRoleParticipant
    @State private var ownAffiliation = kMucAffiliationNone
    @StateObject var contact: ObservableKVOWrapper<MLContact>
    @State private var showingRemoveAvatarConfirmation = false
    @State private var showingBlockContactConfirmation = false
    @State private var showingCannotBlockAlert = false
    @State private var showingRemoveContactConfirmation = false
    @State private var showingAddContactConfirmation = false
    @State private var showingClearHistoryConfirmation = false
    @State private var showingResetOmemoSessionConfirmation = false
    @State private var showingCannotEncryptAlert = false
    @State private var showingShouldDisableEncryptionAlert = false
    @State private var isEditingNickname = false
    @State private var inputImage: UIImage?
    @State private var showingImagePicker = false
    @State private var showingSheetEditSubject = false
    @State private var showingDestroyConfirmation = false
    @State private var alertPrompt = AlertPrompt(dismissLabel: Text("Close"))
    @State private var showAlert = false
    @State private var success = false
    @State private var successCallback: monal_void_block_t?
    @StateObject private var overlay = LoadingOverlayState()

    init(delegate: SheetDismisserProtocol, contact: ObservableKVOWrapper<MLContact>) {
        self.delegate = delegate
        _contact = StateObject(wrappedValue: contact)
        self.account = contact.obj.account!
    }

    private func updateRoleAndAffiliation() {
        if contact.isMuc {
            self.ownRole = DataLayer.sharedInstance().getOwnRole(inGroupOrChannel: contact.obj) ?? kMucRoleNone
            self.ownAffiliation = DataLayer.sharedInstance().getOwnAffiliation(inGroupOrChannel:contact.obj) ?? kMucAffiliationNone
        } else {
            self.ownRole = kMucRoleParticipant
            self.ownAffiliation = kMucAffiliationNone
        }
    }
    
    private func errorAlert(title: Text, message: Text = Text("")) {
        alertPrompt.title = title
        alertPrompt.message = message
        showAlert = true
    }
    
    private func successAlert(title: Text, message: Text = Text("")) {
        alertPrompt.title = title
        alertPrompt.message = message
        showAlert = true
        success = true // < dismiss entire view on close
    }
    
    private func showImagePicker() {
#if targetEnvironment(macCatalyst)
        let picker = DocumentPickerViewController(
            supportedTypes: [UTType.image], 
            onPick: { url in
                if let imageData = try? Data(contentsOf: url) {
                    if let loadedImage = UIImage(data: imageData) {
                            self.inputImage = loadedImage
                    }
                }
            },
            onDismiss: {
                //do nothing on dismiss
            }
        )
        UIApplication.shared.windows.first?.rootViewController?.present(picker, animated: true)
#else
        showingImagePicker = true
#endif
    }
    
    var body: some View {
        Form {
            Section {
                VStack(spacing: 20) {
                    if !contact.isSelfChat {
                        Image(uiImage: contact.avatar)
                            .resizable()
                            .scaledToFit()
                            .applyClosure {view in
                                if contact.isMuc {
                                    if ownAffiliation == kMucAffiliationOwner {
                                        view.accessibilityLabel((contact.mucType == kMucTypeGroup) ? Text("Change Group Avatar") : Text("Change Channel Avatar"))
                                            .onTapGesture {
                                                showImagePicker()
                                            }
                                            .addTopRight {
                                                if contact.hasAvatar {
                                                    Button(action: {
                                                        showingRemoveAvatarConfirmation = true
                                                    }, label: {
                                                        Image(systemName: "xmark.circle.fill")
                                                            .resizable()
                                                            .frame(width: 24.0, height: 24.0)
                                                            .accessibilityLabel((contact.mucType == kMucTypeGroup) ? Text("Remove Group Avatar") : Text("Remove Channel Avatar"))
                                                            .symbolRenderingMode(.palette)
                                                            .foregroundStyle(.white, .red)
                                                    })
                                                    .buttonStyle(.borderless)
                                                    .offset(x: 8, y: -8)
                                                } else {
                                                    Button(action: {
                                                        showImagePicker()
                                                    }, label: {
                                                        Image(systemName: "pencil.circle.fill")
                                                            .resizable()
                                                            .frame(width: 24.0, height: 24.0)
                                                            .accessibilityLabel((contact.mucType == kMucTypeGroup) ? Text("Change Group Avatar") : Text("Change Channel Avatar"))
                                                    })
                                                    .buttonStyle(.borderless)
                                                    .offset(x: 8, y: -8)
                                                }
                                            }
                                    } else {
                                        view.accessibilityLabel((contact.mucType == kMucTypeGroup) ? Text("Group Avatar") : Text("Channel Avatar"))
                                    }
                                } else {
                                    view.accessibilityLabel(Text("Avatar"))
                                }
                            }
                            .frame(width: 150, height: 150, alignment: .center)
                            .shadow(radius: 7)
                            .actionSheet(isPresented: $showingRemoveAvatarConfirmation) {
                                ActionSheet(
                                    title: Text("Really remove avatar?"),
                                    message: Text("This will remove the current avatar image and revert this group/channel to the default one."),
                                    buttons: [
                                        .cancel(),
                                        .destructive(
                                            Text("Yes"),
                                            action: {
                                                showPromisingLoadingOverlay(overlay, headlineView:Text("Removing avatar..."), descriptionView:Text("")) {
                                                    promisifyMucAction(account:account, mucJid:contact.contactJid) {
                                                        self.account.mucProcessor.publishAvatar(nil, forMuc: contact.contactJid)
                                                    }
                                                }.catch { error in
                                                    errorAlert(title: Text("Error removing avatar!"), message: Text("\(String(describing:error))"))
                                                    hideLoadingOverlay(overlay)
                                                }
                                            }
                                        )
                                    ]
                                )
                            }
                    }
                    
                    Button {
                        UIPasteboard.general.setValue(contact.contactJid as String, forPasteboardType:UTType.utf8PlainText.identifier as String)
                        UIAccessibility.post(notification: .announcement, argument: "JID Copied")
                    } label: {
                        HStack {
                            Text(contact.contactJid as String)
                            
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.primary)
                                .accessibilityHidden(true)
                        }
                        .accessibilityHint("Copies JID")
                    }
                    .buttonStyle(.borderless)
                    
//                     //TODO: wait for account edit to become swiftui
//                     if contact.isSelfChat {
//                         Button {
//                             //TODO: open account edit
//                         } label: {
//                             Text("Open account settings")
//                             .accessibilityHint("Open account settings")
//                         }
//                         .buttonStyle(.borderless)
//                     }
                    
                    
                    //only show account jid if more than one is configured
                    if MLXMPPManager.sharedInstance().connectedXMPP.count > 1 && !contact.isSelfChat {
                        Text("Account: \(account.connectionProperties.identity.jid)")
                    }
                    
                    if !contact.isSelfChat && !contact.isMuc {
                        if let lastInteractionTime = contact.lastInteractionTime as Date? {
                            if lastInteractionTime.timeIntervalSince1970 > 0 {
                                Text(String(format: NSLocalizedString("Last seen: %@", comment: ""),
                                    DateFormatter.localizedString(from: lastInteractionTime, dateStyle: DateFormatter.Style.short, timeStyle: DateFormatter.Style.short)))
                            } else {
                                Text(String(format: NSLocalizedString("Last seen: %@", comment: ""), NSLocalizedString("now", comment: "")))
                            }
                        } else {
                            Text(String(format: NSLocalizedString("Last seen: %@", comment: ""), NSLocalizedString("unknown", comment: "")))
                        }
                    }
                    
                    if !contact.isMuc, let statusMessage = contact.statusMessage as String?, statusMessage.count > 0 {
                        VStack {
                            Text("Status message:")
                            Text(contact.statusMessage as String)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    
                    if contact.isMuc && ((contact.groupSubject as String).count > 0 || ownRole == kMucRoleModerator) {
                        VStack {
                            if ownRole == kMucRoleModerator {
                                Button {
                                    showingSheetEditSubject.toggle()
                                } label: {
                                    if contact.obj.mucType == kMucTypeGroup {
                                        HStack {
                                            Text("Group subject:")
                                            Spacer().frame(width:8)
                                            Image(systemName: "pencil")
                                                .foregroundColor(.primary)
                                                .accessibilityHidden(true)
                                        }
                                        .accessibilityHint("Edit Group Subject")
                                    } else {
                                        HStack {
                                            Text("Channel subject:")
                                            Spacer().frame(width:8)
                                            Image(systemName: "pencil")
                                                .foregroundColor(.primary)
                                                .accessibilityHidden(true)
                                        }
                                        .accessibilityHint("Edit Channel Subject")
                                    }
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Text("Group subject:")
                            }
                            
                            Text(contact.groupSubject as String)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .foregroundColor(.primary)
                .padding([.top, .bottom])
                .frame(maxWidth: .infinity)
            }
            
            // info/nondestructive buttons
            Section {
                if !contact.isSelfChat {
                    Button {
                        if contact.isMuc {
                            if !contact.isMuted && !contact.isMentionOnly {
                                contact.obj.toggleMentionOnly(true)
                            } else if !contact.isMuted && contact.isMentionOnly {
                                contact.obj.toggleMentionOnly(false)
                                contact.obj.toggleMute(true)
                            } else {
                                contact.obj.toggleMentionOnly(false)
                                contact.obj.toggleMute(false)
                            }
                        } else {
                            contact.obj.toggleMute(!contact.isMuted)
                        }
                    } label: {
                        if contact.isMuted  {
                            Label {
                                contact.isMuc ? Text("Notifications disabled") : Text("Contact is muted")
                            } icon: {
                                Image(systemName: "bell.slash.fill")
                                    .foregroundColor(.red)
                            }
                        } else if contact.isMuc && contact.isMentionOnly {
                            Label {
                                Text("Notify only when mentioned")
                            } icon: {
                                Image(systemName: "bell.badge")
                                    .foregroundColor(.primary)
                            }
                        } else {
                            Label {
                                contact.isMuc ? Text("Notify on all messages") : Text("Contact is not muted")
                            } icon: {
                                Image(systemName: "bell.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .tint(Color.primary)
                }
                
#if !DISABLE_OMEMO
                if (!contact.isMuc || (contact.isMuc && contact.mucType == kMucTypeGroup)) && !HelperTools.isContactBlacklisted(forEncryption:contact.obj) {
                    Button {
                        if contact.isEncrypted {
                            showingShouldDisableEncryptionAlert = true
                        } else {
                            showingCannotEncryptAlert = !contact.obj.toggleEncryption(!contact.isEncrypted)
                        }
                    } label: {
                        if contact.isEncrypted {
                            Label {
                                Text("Messages are encrypted")
                            } icon: {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.green)
                            }
                        } else {
                            Label {
                                Text("Messages are NOT encrypted")
                            } icon: {
                                Image(systemName: "lock.open.fill")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .alert(isPresented: $showingCannotEncryptAlert) {
                        Alert(title: Text("No OMEMO keys found"), message: Text("This contact may not support OMEMO encrypted messages. Please try again in a few seconds."), dismissButton: .default(Text("Close")))
                    }
                    .actionSheet(isPresented: $showingShouldDisableEncryptionAlert) {
                        ActionSheet(
                            title: Text("Disable encryption?"),
                            message: Text("Do you really want to disable encryption for this contact?"),
                            buttons: [
                                .cancel(
                                    Text("No, keep encryption activated"),
                                    action: { }
                                ),
                                .destructive(
                                    Text("Yes, deactivate encryption"),
                                    action: {
                                        showingCannotEncryptAlert = !contact.obj.toggleEncryption(!contact.isEncrypted)
                                    }
                                )
                            ]
                        )
                    }
                    //.buttonStyle(BorderlessButtonStyle())
                }
#endif
                
                if contact.isMuc && ownAffiliation == kMucAffiliationOwner {
                    let label = contact.obj.mucType == kMucTypeGroup ? NSLocalizedString("Rename Group", comment:"") : NSLocalizedString("Rename Channel", comment:"")
                    TextField(label, text: $contact.fullNameView, onEditingChanged: {
                        isEditingNickname = $0
                    })
                    .accessibilityLabel(contact.obj.mucType == kMucTypeGroup ? Text("Group name") : Text("Channel name"))
                    .addClearButton(isEditing: isEditingNickname, text: $contact.fullNameView)
                } else if !contact.isMuc && !contact.isSelfChat {
                    TextField(NSLocalizedString("Rename Contact", comment: "placeholder text in contact details"), text: $contact.nickNameView, onEditingChanged: {
                        isEditingNickname = $0
                    })
                    .accessibilityLabel(Text("Nickname"))
                    .addClearButton(isEditing: isEditingNickname, text: $contact.nickNameView)
                }
                
                Toggle(isOn: Binding(get: {
                    contact.isPinned
                }, set: {
                    contact.obj.togglePinnedChat($0)
                })) {
                    Text("Pin Chat")
                }
                
#if !DISABLE_OMEMO
                if !HelperTools.isContactBlacklisted(forEncryption:contact.obj) && !contact.isSelfChat {
                    if !contact.isMuc || contact.mucType == kMucTypeGroup {
                        NavigationLink(destination: LazyClosureView(OmemoKeysView(omemoKeys: OmemoKeysForChat(viewContact: contact)))) {
                            Text("Encryption Keys")
                        }
                    }
                }
#endif
                
                if !contact.isMuc && !contact.isSelfChat {
                    NavigationLink(destination: LazyClosureView(ContactResources(contact: contact))) {
                        Text("Resources")
                    }
                }
                
                let accountJid = account.connectionProperties.identity.jid
                let displayName = contact.contactDisplayName as String
                let sharedUrl = HelperTools.getSharedDocumentsURL(forPathComponents:[accountJid, displayName])
                if UIApplication.shared.canOpenURL(sharedUrl) && FileManager.default.fileExists(atPath:sharedUrl.path) {
                    Button(action: {
                            UIApplication.shared.open(sharedUrl, options:[:])
                    }) {
                        Text("Show shared Media and Files")
                    }
                    .tint(Color.primary)
                }
                NavigationLink(destination: LazyClosureView{MediaGalleryView(contact: contact.contactJid as String, accountID: contact.accountID)}) {
                    Text("View Media Gallery")
                }
                
                NavigationLink(destination: LazyClosureView(BackgroundSettings(contact:contact))) {
                    Text("Change Chat Background")
                }
                
                if contact.obj.isMuc && contact.obj.mucType == kMucTypeGroup {
                    NavigationLink(destination: LazyClosureView(MemberList(mucContact:contact))) {
                        Text("Group Members")
                    }
                } else if contact.obj.isMuc && contact.obj.mucType == kMucTypeChannel {
                    if [kMucAffiliationOwner, kMucAffiliationAdmin].contains(ownAffiliation) {
                        NavigationLink(destination: LazyClosureView(MemberList(mucContact:contact))) {
                            Text("Channel Participants")
                        }
                    } else {
                        NavigationLink(destination: LazyClosureView(ChannelMemberList(mucContact:contact))) {
                            Text("Channel Participants")
                        }
                    }
                }
            }
            .listStyle(.plain)

            Section { // the destructive section...
                if !contact.isSelfChat {
                    Button(action: {
                        if !contact.isBlocked {
                            showingBlockContactConfirmation = true
                        } else {
                            showingCannotBlockAlert = !contact.obj.toggleBlocked(!contact.isBlocked)
                        }
                    }) {
                        if !contact.isBlocked {
                            Text("Block Contact")
                                .foregroundColor(.red)
                        } else {
                            Text("Unblock Contact")
                        }
                    }
                    .alert(isPresented: $showingCannotBlockAlert) {
                        Alert(title: Text("Blocking/Unblocking Not Supported"), message: Text("The server does not support blocking (XEP-0191)."), dismissButton: .default(Text("Close")))
                    }
                    .actionSheet(isPresented: $showingBlockContactConfirmation) {
                        ActionSheet(
                            title: Text("Block Contact"),
                            message: Text("Do you really want to block this contact? You won't receive any messages from this contact."),
                            buttons: [
                                .cancel(),
                                .destructive(
                                    Text("Yes"),
                                    action: {
                                        showingCannotBlockAlert = !contact.obj.toggleBlocked(!contact.isBlocked)
                                    }
                                )
                            ]
                        )
                    }

                    Group {
                        if contact.isInRoster {
                            Button(action: {
                                showingRemoveContactConfirmation = true
                            }) {
                                if contact.isMuc {
                                    if contact.mucType == kMucTypeGroup {
                                        Text("Leave Group")
                                            .foregroundColor(.red)
                                    } else {
                                        Text("Leave Channel")
                                            .foregroundColor(.red)
                                    }
                                } else {
                                    Text("Remove from contacts")
                                        .foregroundColor(.red)
                                }
                            }
                            .actionSheet(isPresented: $showingRemoveContactConfirmation) {
                                ActionSheet(
                                    title: Text(contact.isMuc ? NSLocalizedString("Leave this conversation", comment: "") : String(format: NSLocalizedString("Remove %@ from contacts?", comment: ""), contact.contactJid)),
                                        message: Text(contact.isMuc ? NSLocalizedString("You will no longer receive messages from this conversation", comment: "") : NSLocalizedString("They will no longer see when you are online. They may not be able to send you encrypted messages.", comment: "")),
                                    buttons: [
                                        .cancel(),
                                        .destructive(
                                            Text("Yes"),
                                            action: {
                                                contact.obj.removeFromRoster()      //this will dismiss the chatview via kMonalContactRemoved notification
                                                //this will do nothing for contact details opened through group members list (which is fine!)
                                                //NOTE: this holds for all delegate.dismiss() calls
                                                self.delegate.dismiss()
                                            }
                                        )
                                    ]
                                )
                            }
                        } else {
                            Button(action: {
                                showingAddContactConfirmation = true
                            }) {
                                if contact.isMuc {
                                    if contact.mucType == kMucTypeGroup {
                                        Text("Join Group")
                                    } else {
                                        Text("Join Channel")
                                    }
                                } else {
                                    Text("Add to contacts")
                                }
                            }
                            .actionSheet(isPresented: $showingAddContactConfirmation) {
                                ActionSheet(
                                    title: Text(contact.isMuc ? (contact.mucType == kMucTypeGroup ? NSLocalizedString("Join Group", comment: "") : NSLocalizedString("Join Channel", comment: "")) : String(format: NSLocalizedString("Add %@ to your contacts?", comment: ""), contact.contactJid)),
                                    message: Text(contact.isMuc ? NSLocalizedString("You will receive subsequent messages from this conversation", comment: "") : NSLocalizedString("They will see when you are online. They will be able to send you encrypted messages.", comment: "")),
                                    buttons: [
                                        .cancel(),
                                        .default(
                                            Text("Yes"),
                                            action: {
                                                contact.obj.addToRoster()
                                            }
                                        ),
                                    ]
                                )
                            }
                        }
                    }
                }

                if ownAffiliation == kMucAffiliationOwner {
                    Section {
                        Button(action: {
                            showingDestroyConfirmation = true
                        }) {
                            if contact.mucType == kMucTypeGroup {
                                Text("Destroy Group").foregroundColor(.red)
                            } else {
                                Text("Destroy Channel").foregroundColor(.red)
                            }
                        }
                        .actionSheet(isPresented: $showingDestroyConfirmation) {
                            ActionSheet(
                                title: contact.mucType == kMucTypeGroup ? Text("Destroy Group") : Text("Destroy Channel"),
                                message: contact.mucType == kMucTypeGroup ? Text("Do you really want to destroy this group? Every member will be kicked out and it will be destroyed afterwards.") : Text("Do you really want to destroy this channel? Every member will be kicked out and it will be destroyed afterwards."),
                                buttons: [
                                    .cancel(),
                                    .destructive(
                                        Text("Yes"),
                                        action: {
                                            showPromisingLoadingOverlay(overlay, headlineView:contact.mucType == kMucTypeGroup ? Text("Destroying group...") : Text("Destroying channel..."), descriptionView:Text("")) {
                                                promisifyMucAction(account:account, mucJid:contact.contactJid) {
                                                    self.account.mucProcessor.destroyRoom(contact.contactJid as String)
                                                }
                                            }.done { callback in
                                                if let callback = callback {
                                                    self.successCallback = callback
                                                }
                                                successAlert(title: Text("Success"), message: contact.mucType == kMucTypeGroup ? Text("Successfully destroyed group.") : Text("Successfully destroyed channel."))
                                            }.catch { error in
                                                errorAlert(title: Text("Error destroying group!"), message: Text("\(String(describing:error))"))
                                            }
                                        }
                                    )
                                ]
                            )
                        }
                    }
                }
                
                Button(action: {
                    showingClearHistoryConfirmation = true
                }) {
                    if contact.isMuc {
                        if contact.obj.mucType == kMucTypeGroup {
                            Text("Clear chat history of this group")
                        } else {
                            Text("Clear chat history of this channel")
                        }
                    } else {
                        Text("Clear chat history of this contact")
                    }
                }
                .foregroundColor(.red)
                .actionSheet(isPresented: $showingClearHistoryConfirmation) {
                    ActionSheet(
                        title: Text("Clear History"),
                        message: Text("Do you really want to clear all messages exchanged in this conversation? If using OMEMO you won't even be able to load them from your server again."),
                        buttons: [
                            .cancel(),
                            .destructive(
                                Text("Yes"),
                                action: {
                                    contact.obj.clearHistory()
                                }
                            )
                        ]
                    )
                }
            }
            
#if !DISABLE_OMEMO
            //omemo debug stuff, should be removed in a few months
            Section {
                // only display omemo session reset button on 1:1 and private groups
                if contact.obj.isMuc == false || (contact.isMuc && contact.mucType == kMucTypeGroup) {
                    Button(action: {
                        showingResetOmemoSessionConfirmation = true
                    }) {
                        Text("Reset OMEMO session")
                            .foregroundColor(.red)
                    }
                    .actionSheet(isPresented: $showingResetOmemoSessionConfirmation) {
                        ActionSheet(
                            title: Text("Reset OMEMO session"),
                            message: Text("Do you really want to reset the OMEMO session? You should only reset the connection if you know what you are doing!"),
                            buttons: [
                                .cancel(),
                                .destructive(
                                    Text("Yes"),
                                    action: {
                                        self.account.omemo.clearAllSessions(forJid:contact.contactJid);
                                    }
                                )
                            ]
                        )
                    }
                }
            }
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .addLoadingOverlay(overlay)
        .navigationBarTitle(contact.contactDisplayName as String, displayMode:.inline)
        .alert(isPresented: $showAlert) {
            Alert(title: alertPrompt.title, message: alertPrompt.message, dismissButton:.default(Text("Close"), action: {
                showAlert = false
                if self.success == true {
                    if let callback = self.successCallback {
                        callback()
                    }
                    //close muc ui and leave chat ui of this muc
                    if let activeChats = (UIApplication.shared.delegate as! MonalAppDelegate).activeChats {
                        activeChats.presentChat(with:nil)
                    }
                }
            }))
        }
        .sheet(isPresented: $showingSheetEditSubject) {
            LazyClosureView(EditGroupSubject(contact: contact))
        }
        .sheet(isPresented:$showingImagePicker) {
            ImagePicker(image:$inputImage)
        }
        .sheet(isPresented: $inputImage.optionalMappedToBool()) {
            ImageCropView(originalImage: inputImage!, configureBlock: { cropViewController in
                cropViewController.aspectRatioPreset = .presetSquare
                cropViewController.aspectRatioLockEnabled = true
                cropViewController.aspectRatioPickerButtonHidden = true
                cropViewController.resetAspectRatioEnabled = false
            }, onCanceled: {
                inputImage = nil
            }) { (image, cropRect, angle) in
                showPromisingLoadingOverlay(overlay, headlineView:Text("Uploading avatar..."), descriptionView:Text("")) {
                    promisifyMucAction(account:account, mucJid:contact.contactJid) {
                        self.account.mucProcessor.publishAvatar(image, forMuc: contact.contactJid)
                    }
                }.catch { error in
                    errorAlert(title: Text("Error changing avatar!"), message: Text("\(String(describing:error))"))
                    hideLoadingOverlay(overlay)
                }
            }
        }
        .onChange(of:contact.avatar as UIImage) { _ in
            hideLoadingOverlay(overlay)
        }
        .onAppear {
            self.updateRoleAndAffiliation()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("kMonalMucParticipantsAndMembersUpdated")).receive(on: RunLoop.main)) { notification in
            if let xmppAccount = notification.object as? xmpp, let notificationContact = notification.userInfo?["contact"] as? MLContact {
                DDLogVerbose("Got muc participants/members update from account \(xmppAccount)...")
                if notificationContact == contact {
                    self.updateRoleAndAffiliation()
                }
            }
        }
    }
}

struct ContactDetails_Previews: PreviewProvider {
    static var delegate = SheetDismisserProtocol()
    static var previews: some View {
        ContactDetails(delegate:delegate, contact:ObservableKVOWrapper<MLContact>(MLContact.makeDummyContact(0)))
        ContactDetails(delegate:delegate, contact:ObservableKVOWrapper<MLContact>(MLContact.makeDummyContact(1)))
        ContactDetails(delegate:delegate, contact:ObservableKVOWrapper<MLContact>(MLContact.makeDummyContact(2)))
        ContactDetails(delegate:delegate, contact:ObservableKVOWrapper<MLContact>(MLContact.makeDummyContact(3)))
        ContactDetails(delegate:delegate, contact:ObservableKVOWrapper<MLContact>(MLContact.makeDummyContact(4)))
    }
}
