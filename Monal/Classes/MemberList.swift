//
//  MemberList.swift
//  Monal
//
//  Created by Jan on 28.05.22.
//  Copyright © 2022 Monal.im. All rights reserved.
//

import OrderedCollections

struct ActionSheetPrompt {
    var title: Text = Text("")
    var message: Text = Text("")
    var closure: ()->Void = { }
}

struct MemberList: View {
    private let account: xmpp
    @State private var ownAffiliation: String
    @StateObject var muc: ObservableKVOWrapper<MLContact>
    @State private var memberList: OrderedSet<ObservableKVOWrapper<MLContact>>
    @State private var affiliations: Dictionary<ObservableKVOWrapper<MLContact>, String>
    @State private var online: Dictionary<ObservableKVOWrapper<MLContact>, Bool>
    @State private var nicknames: Dictionary<ObservableKVOWrapper<MLContact>, String>
    @State private var navigationActive: ObservableKVOWrapper<MLContact>?
    @State private var showAlert = false
    @State private var alertPrompt = AlertPrompt(dismissLabel: Text("Close"))
    @State private var showActionSheet = false
    @State private var actionSheetPrompt = ActionSheetPrompt()
    @StateObject private var overlay = LoadingOverlayState()

    init(mucContact: ObservableKVOWrapper<MLContact>) {
        account = mucContact.obj.account! as xmpp
        _muc = StateObject(wrappedValue:mucContact)
        _ownAffiliation = State(wrappedValue:kMucAffiliationNone)
        _memberList = State(wrappedValue:OrderedSet<ObservableKVOWrapper<MLContact>>())
        _affiliations = State(wrappedValue:[:])
        _online = State(wrappedValue:[:])
        _nicknames = State(wrappedValue:[:])
    }
    
    func updateMemberlist() {
        memberList = getContactList(viewContact:self.muc)
        ownAffiliation = DataLayer.sharedInstance().getOwnAffiliation(inGroupOrChannel:self.muc.obj) ?? kMucAffiliationNone
        affiliations.removeAll(keepingCapacity:true)
        online.removeAll(keepingCapacity:true)
        nicknames.removeAll(keepingCapacity:true)
        for memberInfo in Array(DataLayer.sharedInstance().getMembersAndParticipants(ofMuc:self.muc.contactJid, forAccountID:account.accountID)) {
            DDLogVerbose("Got member/participant entry: \(String(describing:memberInfo))")
            guard let jid = memberInfo["participant_jid"] as? String ?? memberInfo["member_jid"] as? String else {
                continue
            }
            let contact = ObservableKVOWrapper(MLContact.createContact(fromJid:jid, andAccountID:account.accountID))
            nicknames[contact] = memberInfo["room_nick"] as? String
            if !memberList.contains(contact) {
                continue
            }
            affiliations[contact] = memberInfo["affiliation"] as? String ?? kMucAffiliationNone
            if let num = memberInfo["online"] as? NSNumber {
                online[contact] = num.boolValue
            } else {
                online[contact] = false
            }
        }
        //this is needed to improve sorting speed
        var contactNames: [ObservableKVOWrapper<MLContact>:String] = [:]
        for contact in memberList {
            contactNames[contact] = contact.obj.contactDisplayName(withFallback:nicknames[contact], andSelfnotesPrefix:false)
        }
        //sort our member list
        memberList.sort {
            (
                (online[$0]! ? 0 : 1),
                mucAffiliationToInt(affiliations[$0]),
                (contactNames[$0]!.lowercased()),
                ($0.contactJid as String)
            ) < (
                (online[$1]! ? 0 : 1),
                mucAffiliationToInt(affiliations[$1]),
                (contactNames[$1]!.lowercased()),
                ($1.contactJid as String)
            )
        }
    }
    
    func promisifyAction(action: @escaping ()->Void) -> Promise<monal_void_block_t?> {
        return promisifyMucAction(account:self.account, mucJid:self.muc.contactJid, action:action)
    }

    func showAlert(title: Text, description: Text) {
        self.alertPrompt.title = title
        self.alertPrompt.message = description
        self.showAlert = true
    }
    
    func showActionSheet(title: Text, description: Text, closure: @escaping ()->Void) {
        self.actionSheetPrompt.title = title
        self.actionSheetPrompt.message = description
        self.actionSheetPrompt.closure = closure
        self.showActionSheet = true
    }

    func ownUserHasAffiliationToRemove(contact: ObservableKVOWrapper<MLContact>) -> Bool {
        //we don't want to set affiliation=none in channels using deletion swipe (this does not delete the user)
        if self.muc.mucType == kMucTypeChannel {
            return false
        }
        if contact.contactJid == account.connectionProperties.identity.jid {
            return false
        }
        if let contactAffiliation = affiliations[contact] {
            if ownAffiliation == kMucAffiliationOwner {
                return true
            } else if ownAffiliation == kMucAffiliationAdmin && (contactAffiliation != kMucAffiliationOwner && contactAffiliation != kMucAffiliationAdmin) {
                return true
            }
        }
        return false
    }
    
    func actionsAllowed(for contact:ObservableKVOWrapper<MLContact>) -> [String] {
        if let contactAffiliation = affiliations[contact], let contactOnline = online[contact] {
            var reinviteEntry: [String] = []
            if !contactOnline {
                reinviteEntry = [kMucActionReinvite]
            }
            if self.muc.mucType == kMucTypeGroup {
                if ownAffiliation == kMucAffiliationOwner {
                    return [/*kMucActionShowProfile*/] + reinviteEntry + [kMucAffiliationOwner, kMucAffiliationAdmin, kMucAffiliationMember, kMucAffiliationOutcast]
                } else {        //only admin left, because other affiliations don't call actionsAllowed at all
                    if [kMucAffiliationMember, kMucAffiliationOutcast].contains(contactAffiliation) {
                        return [/*kMucActionShowProfile*/] + reinviteEntry + [kMucAffiliationMember, kMucAffiliationOutcast]
                    } else {
                        //if this contact is a co-admin or owner, we aren't allowed to do much to their affiliation
                        //return contact affiliation because that should be displayed as selected in picker
                        return [/*kMucActionShowProfile*/] + reinviteEntry + [contactAffiliation]
                    }
                }
            } else {
                if ownAffiliation == kMucAffiliationOwner {
                    return [/*kMucActionShowProfile*/] + reinviteEntry + [kMucAffiliationOwner, kMucAffiliationAdmin, kMucAffiliationMember, kMucAffiliationNone, kMucAffiliationOutcast]
                } else {        //only admin left, because other affiliations don't call actionsAllowed at all
                    if [kMucAffiliationMember, kMucAffiliationNone, kMucAffiliationOutcast].contains(contactAffiliation) {
                        return [/*kMucActionShowProfile*/] + reinviteEntry + [kMucAffiliationMember, kMucAffiliationNone, kMucAffiliationOutcast]
                    } else {
                        //if this contact is a co-admin or owner, we aren't allowed to do much to their affiliation
                        //return contact affiliation because that should be displayed as selected in picker
                        return [/*kMucActionShowProfile*/] + reinviteEntry + [contactAffiliation]
                    }
                }
            }
        }
        //fallback (should hopefully never be needed)
        DDLogWarn("Fallback for group/channel \(String(describing:self.muc.contactJid as String)): affiliation=\(String(describing:affiliations[contact])), online=\(String(describing:online[contact]))")
        if self.muc.mucType == kMucTypeGroup {
            return [/*kMucActionShowProfile,*/ kMucActionReinvite]
        } else {
            return [/*kMucActionShowProfile,*/ kMucActionReinvite, kMucAffiliationNone]
        }
    }
    
    @ViewBuilder
    func makePickerView(contact: ObservableKVOWrapper<MLContact>) -> some View {
        Picker(selection: Binding<String>(
            get: { affiliations[contact] ?? kMucAffiliationNone },
            set: { newAffiliation in
                if newAffiliation == affiliations[contact] {
                    return
                }
                if newAffiliation == kMucActionShowProfile {
                    DDLogVerbose("Activating navigation to \(String(describing:contact))")
                    navigationActive = contact
                } else if newAffiliation == kMucActionReinvite {
                    //first remove potential ban, then reinvite
                    var outcastResolution: Promise<monal_void_block_t?> = Promise.value(nil)
                    if affiliations[contact] == kMucAffiliationOutcast {
                        outcastResolution = showPromisingLoadingOverlay(self.overlay, headlineView: Text("Unblocking user"), descriptionView: Text("Unblocking user for this group/channel: \(contact.contactJid as String)")) {
                            promisifyAction {
                                account.mucProcessor.setAffiliation(self.muc.mucType == kMucTypeGroup ? kMucAffiliationMember : kMucAffiliationNone, ofUser:contact.contactJid, inMuc:self.muc.contactJid)
                            }
                        }
                    }
                    outcastResolution.then { _ in
                        showPromisingLoadingOverlay(self.overlay, headlineView: Text("Inviting user"), descriptionView: Text("Inviting user to this group/channel: \(contact.contactJid as String)")) {
                            promisifyAction {
                                account.mucProcessor.inviteUser(contact.contactJid, inMuc: self.muc.contactJid)
                            }
                        }.catch { error in
                            showAlert(title:Text("Error inviting user!"), description:Text("\(String(describing:error))"))
                        }
                        return Guarantee.value(())
                    }.catch { error in
                        showAlert(title:Text("Error unblocking user!"), description:Text("\(String(describing:error))"))
                    }
                } else if newAffiliation == kMucAffiliationOutcast {
                    showActionSheet(title: Text("Block user?"), description: Text("Do you want to block this user from entering this group/channel?")) {
                        DDLogVerbose("Changing affiliation of \(String(describing:contact)) to: \(String(describing:newAffiliation))...")
                        showPromisingLoadingOverlay(self.overlay, headlineView: Text("Blocking member"), descriptionView: Text("Blocking \(contact.contactJid as String)")) {
                            promisifyAction {
                                account.mucProcessor.setAffiliation(newAffiliation, ofUser:contact.contactJid, inMuc:self.muc.contactJid)
                            }
                        }.catch { error in
                            showAlert(title:Text("Error blocking user!"), description:Text("\(String(describing:error))"))
                        }
                    }
                } else {
                    DDLogVerbose("Changing affiliation of \(String(describing:contact)) to: \(String(describing:newAffiliation))...")
                    showPromisingLoadingOverlay(self.overlay, headlineView: Text("Changing affiliation"), descriptionView: Text("Changing affiliation to \(mucAffiliationToString(affiliations[contact])): \(contact.contactJid as String)")) {
                        promisifyAction {
                            account.mucProcessor.setAffiliation(newAffiliation, ofUser:contact.contactJid, inMuc:self.muc.contactJid)
                        }
                    }.catch { error in
                        showAlert(title:Text("Error changing affiliation!"), description:Text("\(String(describing:error))"))
                    }
                }
            }
        ), label: EmptyView()) {
            ForEach(actionsAllowed(for:contact), id:\.self) { affiliation in
                Text(mucAffiliationToString(affiliation)).tag(affiliation)
            }
        }.collapsedPickerStyle(accessibilityLabel: Text("Change affiliation"))
    }

    var body: some View {
        List {
            Section(header: Text("\(self.muc.contactDisplayName as String) (affiliation: \(mucAffiliationToString(ownAffiliation)))")) {
                if ownAffiliation == kMucAffiliationOwner || ownAffiliation == kMucAffiliationAdmin {
                    NavigationLink(destination: LazyClosureView(ContactPicker(account, initializeFrom: memberList, allowRemoval: false) { newMemberList in
                        for member in newMemberList {
                            if !memberList.contains(member) {
                                if self.muc.mucType == kMucTypeGroup {
                                    showPromisingLoadingOverlay(self.overlay, headlineView: Text("Adding new member"), descriptionView: Text("Adding \(member.contactJid as String)...")) {
                                        promisifyAction {
                                            account.mucProcessor.setAffiliation(kMucAffiliationMember, ofUser:member.contactJid, inMuc:self.muc.contactJid)
                                        }
                                    }.done { _ in
                                        showPromisingLoadingOverlay(self.overlay, headlineView: Text("Inviting new member"), descriptionView: Text("Adding \(member.contactJid as String)...")) {
                                            promisifyAction {
                                                account.mucProcessor.inviteUser(member.contactJid, inMuc: self.muc.contactJid)
                                            }
                                        }.catch { error in
                                            showAlert(title:Text("Error inviting new member!"), description:Text("\(String(describing:error))"))
                                        }
                                    }.catch { error in
                                        showAlert(title:Text("Error adding new member!"), description:Text("\(String(describing:error))"))
                                    }
                                } else {
                                    showPromisingLoadingOverlay(self.overlay, headlineView: Text("Inviting new participant"), descriptionView: Text("Adding \(member.contactJid as String)...")) {
                                        promisifyAction {
                                            account.mucProcessor.inviteUser(member.contactJid, inMuc: self.muc.contactJid)
                                        }
                                    }.catch { error in
                                        showAlert(title:Text("Error inviting new participant!"), description:Text("\(String(describing:error))"))
                                    }
                                }
                            }
                        }
                    })) {
                        if self.muc.mucType == kMucTypeGroup {
                            Text("Add members to group")
                        } else {
                            Text("Invite participants to channel")
                        }
                    }
                }
                
                ForEach(memberList, id:\.self) { contact in
                    var isDeletable: Bool {
                        ownUserHasAffiliationToRemove(contact: contact)
                    }

                    if !contact.isSelfChat {
                        HStack {
                            HStack {
                                ContactEntry(contact:contact, fallback:nicknames[contact]) {
                                    Text("Affiliation: \(mucAffiliationToString(affiliations[contact]))\(!(online[contact] ?? false) ? Text(" (offline)") : Text(""))")
                                        //.foregroundColor(Color(UIColor.secondaryLabel))
                                        .font(.footnote)
                                }
                                Spacer()
                            }
                            .accessibilityLabel(Text("Open Profile of \(contact.contactDisplayName as String)"))
                            //invisible navigation link that can be triggered programmatically
                            .background(
                                NavigationLink(destination: LazyClosureView(ContactDetails(delegate:SheetDismisserProtocol(), contact:contact)), tag:contact, selection:$navigationActive) { EmptyView() }
                                    .opacity(0)
                            )
                            
                            if ownAffiliation == kMucAffiliationOwner || ownAffiliation == kMucAffiliationAdmin {
                                makePickerView(contact:contact)
                                    .fixedSize()
                                    .offset(x:8, y:0)
                            }
                        }
                        .applyClosure { view in
                            if !(online[contact] ?? false) {
                                view.opacity(0.5)
                            } else {
                                view
                            }
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Delete") {
                                showActionSheet(title: Text("Remove \(mucAffiliationToString(affiliations[contact]))?"), description: self.muc.mucType == kMucTypeGroup ? Text("Do you want to remove that user from this group? That user won't be able to enter it again until added back to the group.") : Text("Do you want to remove that user from this channel? That user will be able to enter it again if you don't block them.")) {
                                    showPromisingLoadingOverlay(self.overlay, headlineView: Text("Removing \(mucAffiliationToString(affiliations[contact]))"), descriptionView: Text("Removing \(contact.contactJid as String)...")) {
                                        promisifyAction {
                                            account.mucProcessor.setAffiliation(kMucAffiliationNone, ofUser: contact.contactJid, inMuc: self.muc.contactJid)
                                        }
                                    }.catch { error in
                                        showAlert(title:Text("Error removing user!"), description:Text("\(String(describing:error))"))
                                    }
                                }
                            }
                            .tint(.red)
                            .disabled(!isDeletable)
                        }
                    }
                }
            }
        }
        .animation(.default, value: memberList)
        .actionSheet(isPresented: $showActionSheet) {
            ActionSheet(
                title: actionSheetPrompt.title,
                message: actionSheetPrompt.message,
                buttons: [
                    .cancel(),
                    .destructive(
                        Text("Yes"),
                        action: actionSheetPrompt.closure
                    )
                ]
            )
        }
        .alert(isPresented: $showAlert, content: {
            Alert(title: alertPrompt.title, message: alertPrompt.message, dismissButton: .default(alertPrompt.dismissLabel))
        })
        .addLoadingOverlay(overlay)
        .navigationBarTitle(Text("Group Members"), displayMode: .inline)
        .onAppear {
            updateMemberlist()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("kMonalMucParticipantsAndMembersUpdated")).receive(on: RunLoop.main)) { notification in
            if let xmppAccount = notification.object as? xmpp, let contact = notification.userInfo?["contact"] as? MLContact {
                DDLogVerbose("Got muc participants/members update from account \(xmppAccount)...")
                //only trigger update if we are either in a group type muc or have admin/owner priviledges
                //all other cases will close this view anyways, it makes no sense to update everything directly before hiding thsi view
                if contact == self.muc && (contact.mucType == kMucTypeGroup || [kMucAffiliationOwner, kMucAffiliationAdmin].contains(DataLayer.sharedInstance().getOwnAffiliation(inGroupOrChannel:self.muc.obj) ?? kMucAffiliationNone)) {
                    updateMemberlist()
                }
            }
        }
    }
}

extension UIPickerView {
    override open func didMoveToSuperview() {
        super.didMoveToSuperview()
        self.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}

struct MemberList_Previews: PreviewProvider {
    static var previews: some View {
        MemberList(mucContact:ObservableKVOWrapper<MLContact>(MLContact.makeDummyContact(2)));
    }
}
