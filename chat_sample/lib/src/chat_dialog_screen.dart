import 'dart:async';
import 'package:chat_sample/src/utils/api_utils.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:intl/intl.dart';

import 'package:connectycube_sdk/connectycube_sdk.dart';

import 'chat_details_screen.dart';
import '../src/utils/consts.dart';
import '../src/widgets/common.dart';
import '../src/widgets/full_photo.dart';
import '../src/widgets/loading.dart';

class ChatDialogScreen extends StatelessWidget {
  final CubeUser _cubeUser;
  final CubeDialog _cubeDialog;

  ChatDialogScreen(this._cubeUser, this._cubeDialog);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _cubeDialog.name != null ? _cubeDialog.name! : '',
        ),
        centerTitle: false,
        actions: <Widget>[
          IconButton(
            onPressed: () => _chatDetails(context),
            icon: Icon(
              Icons.info_outline,
              color: Colors.white,
            ),
          ),
        ],
      ),
      body: ChatScreen(_cubeUser, _cubeDialog),
    );
  }

  _chatDetails(BuildContext context) async {
    log("_chatDetails= $_cubeDialog");
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatDetailsScreen(_cubeUser, _cubeDialog),
      ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  static const String TAG = "_CreateChatScreenState";
  final CubeUser _cubeUser;
  final CubeDialog _cubeDialog;

  ChatScreen(this._cubeUser, this._cubeDialog);

  @override
  State createState() => ChatScreenState(_cubeUser, _cubeDialog);
}

class ChatScreenState extends State<ChatScreen> {
  final CubeUser _cubeUser;
  final CubeDialog _cubeDialog;
  final Map<int?, CubeUser?> _occupants = Map();

  late bool isLoading;
  late StreamSubscription<ConnectivityResult> connectivityStateSubscription;
  String? imageUrl;
  List<CubeMessage> listMessage = [];
  Timer? typingTimer;
  bool isTyping = false;
  String userStatus = '';
  static const int TYPING_TIMEOUT = 700;
  static const int STOP_TYPING_TIMEOUT = 2000;

  int _sendIsTypingTime = DateTime.now().millisecondsSinceEpoch;
  Timer? _sendStopTypingTimer;

  final TextEditingController textEditingController = TextEditingController();
  final ScrollController listScrollController = ScrollController();

  StreamSubscription<CubeMessage>? msgSubscription;
  StreamSubscription<MessageStatus>? deliveredSubscription;
  StreamSubscription<MessageStatus>? readSubscription;
  StreamSubscription<TypingStatus>? typingSubscription;

  List<CubeMessage> _unreadMessages = [];
  List<CubeMessage> _unsentMessages = [];

  static const int messagesPerPage = 50;
  int lastPartSize = 0;

  List<CubeMessage> oldMessages = [];

  ChatScreenState(this._cubeUser, this._cubeDialog);

  @override
  void initState() {
    super.initState();
    _initCubeChat();

    isLoading = false;
    imageUrl = '';
    listScrollController.addListener(onScrollChanged);
    connectivityStateSubscription =
        Connectivity().onConnectivityChanged.listen(onConnectivityChanged);
  }

  @override
  void dispose() {
    msgSubscription?.cancel();
    deliveredSubscription?.cancel();
    readSubscription?.cancel();
    typingSubscription?.cancel();
    textEditingController.dispose();
    connectivityStateSubscription.cancel();
    super.dispose();
  }

  void openGallery() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );

    if (result == null) return;

    setState(() {
      isLoading = true;
    });

    var uploadImageFuture = getUploadingImageFuture(result);
    var imageData;

    if (kIsWeb) {
      imageData = result.files.single.bytes!;
    } else {
      imageData = File(result.files.single.path!).readAsBytesSync();
    }

    var decodedImage = await decodeImageFromList(imageData);

    uploadImageFile(uploadImageFuture, decodedImage);
  }

  Future uploadImageFile(Future<CubeFile> uploadAction, imageData) async {
    uploadAction.then((cubeFile) {
      onSendChatAttachment(cubeFile, imageData);
    }).catchError((ex) {
      setState(() {
        isLoading = false;
      });
      Fluttertoast.showToast(msg: 'This file is not an image');
    });
  }

  void onReceiveMessage(CubeMessage message) {
    log("onReceiveMessage message= $message");
    if (message.dialogId != _cubeDialog.dialogId ||
        message.senderId == _cubeUser.id) return;

    addMessageToListView(message);
  }

  void onDeliveredMessage(MessageStatus status) {
    log("onDeliveredMessage message= $status");
    updateReadDeliveredStatusMessage(status, false);
  }

  void onReadMessage(MessageStatus status) {
    log("onReadMessage message= ${status.messageId}");
    updateReadDeliveredStatusMessage(status, true);
  }

  void onTypingMessage(TypingStatus status) {
    log("TypingStatus message= ${status.userId}");
    if (status.userId == _cubeUser.id ||
        (status.dialogId != null && status.dialogId != _cubeDialog.dialogId))
      return;
    userStatus = _occupants[status.userId]?.fullName ??
        _occupants[status.userId]?.login ??
        '';
    if (userStatus.isEmpty) return;
    userStatus = "$userStatus is typing ...";

    if (isTyping != true) {
      setState(() {
        isTyping = true;
      });
    }
    startTypingTimer();
  }

  startTypingTimer() {
    typingTimer?.cancel();
    typingTimer = Timer(Duration(milliseconds: 900), () {
      setState(() {
        isTyping = false;
      });
    });
  }

  void onSendChatMessage(String content) {
    if (content.trim() != '') {
      final message = createCubeMsg();
      message.body = content.trim();
      onSendMessage(message);
    } else {
      Fluttertoast.showToast(msg: 'Nothing to send');
    }
  }

  void onSendChatAttachment(CubeFile cubeFile, imageData) async {
    final attachment = CubeAttachment();
    attachment.id = cubeFile.uid;
    attachment.type = CubeAttachmentType.IMAGE_TYPE;
    attachment.url = cubeFile.getPublicUrl();
    attachment.height = imageData.height;
    attachment.width = imageData.width;
    final message = createCubeMsg();
    message.body = "Attachment";
    message.attachments = [attachment];
    onSendMessage(message);
  }

  CubeMessage createCubeMsg() {
    var message = CubeMessage();
    message.dateSent = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    message.markable = true;
    message.saveToHistory = true;
    return message;
  }

  void onSendMessage(CubeMessage message) async {
    log("onSendMessage message= $message");
    textEditingController.clear();
    await _cubeDialog.sendMessage(message);
    message.senderId = _cubeUser.id;
    addMessageToListView(message);
    listScrollController.animateTo(0.0,
        duration: Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  updateReadDeliveredStatusMessage(MessageStatus status, bool isRead) {
    log('[updateReadDeliveredStatusMessage]');
    setState(() {
      CubeMessage? msg = listMessage
          .firstWhereOrNull((msg) => msg.messageId == status.messageId);
      if (msg == null) return;
      if (isRead)
        msg.readIds == null
            ? msg.readIds = [status.userId]
            : msg.readIds?.add(status.userId);
      else
        msg.deliveredIds == null
            ? msg.deliveredIds = [status.userId]
            : msg.deliveredIds?.add(status.userId);

      log('[updateReadDeliveredStatusMessage] status updated for $msg');
    });
  }

  addMessageToListView(CubeMessage message) {
    setState(() {
      isLoading = false;
      int existMessageIndex = listMessage.indexWhere((cubeMessage) {
        return cubeMessage.messageId == message.messageId;
      });

      if (existMessageIndex != -1) {
        listMessage[existMessageIndex] = message;
      } else {
        listMessage.insert(0, message);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      child: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              // List of messages
              buildListMessage(),
              //Typing content
              buildTyping(),
              // Input content
              buildInput(),
            ],
          ),

          // Loading
          buildLoading()
        ],
      ),
      onWillPop: onBackPress,
    );
  }

  Widget buildItem(int index, CubeMessage message) {
    markAsReadIfNeed() {
      var isOpponentMsgRead =
          message.readIds != null && message.readIds!.contains(_cubeUser.id);
      print(
          "markAsReadIfNeed message= $message, isOpponentMsgRead= $isOpponentMsgRead");
      if (message.senderId != _cubeUser.id && !isOpponentMsgRead) {
        if (message.readIds == null) {
          message.readIds = [_cubeUser.id!];
        } else {
          message.readIds!.add(_cubeUser.id!);
        }

        if (CubeChatConnection.instance.chatConnectionState ==
            CubeChatConnectionState.Ready) {
          _cubeDialog.readMessage(message);
        } else {
          _unreadMessages.add(message);
        }
      }
    }

    Widget getReadDeliveredWidget() {
      log("[getReadDeliveredWidget]");
      bool messageIsRead() {
        log("[getReadDeliveredWidget] messageIsRead");
        if (_cubeDialog.type == CubeDialogType.PRIVATE)
          return message.readIds != null &&
              (message.recipientId == null ||
                  message.readIds!.contains(message.recipientId));
        return message.readIds != null &&
            message.readIds!.any(
                (int id) => id != _cubeUser.id && _occupants.keys.contains(id));
      }

      bool messageIsDelivered() {
        log("[getReadDeliveredWidget] messageIsDelivered");
        if (_cubeDialog.type == CubeDialogType.PRIVATE)
          return message.deliveredIds != null &&
              (message.recipientId == null ||
                  message.deliveredIds!.contains(message.recipientId));
        return message.deliveredIds != null &&
            message.deliveredIds!.any(
                (int id) => id != _cubeUser.id && _occupants.keys.contains(id));
      }

      if (messageIsRead()) {
        log("[getReadDeliveredWidget] if messageIsRead");
        return Stack(children: <Widget>[
          Icon(
            Icons.check,
            size: 15.0,
            color: blueColor,
          ),
          Padding(
            padding: EdgeInsets.only(left: 8),
            child: Icon(
              Icons.check,
              size: 15.0,
              color: blueColor,
            ),
          )
        ]);
      } else if (messageIsDelivered()) {
        log("[getReadDeliveredWidget] if messageIsDelivered");
        return Stack(children: <Widget>[
          Icon(
            Icons.check,
            size: 15.0,
            color: greyColor,
          ),
          Padding(
            padding: EdgeInsets.only(left: 8),
            child: Icon(
              Icons.check,
              size: 15.0,
              color: greyColor,
            ),
          )
        ]);
      } else {
        log("[getReadDeliveredWidget] sent");
        return Icon(
          Icons.check,
          size: 15.0,
          color: greyColor,
        );
      }
    }

    Widget getDateWidget() {
      return Text(
        DateFormat('HH:mm').format(
            DateTime.fromMillisecondsSinceEpoch(message.dateSent! * 1000)),
        style: TextStyle(
            color: greyColor, fontSize: 12.0, fontStyle: FontStyle.italic),
      );
    }

    Widget getHeaderDateWidget() {
      return Container(
        alignment: Alignment.center,
        child: Text(
          DateFormat('dd MMMM').format(
              DateTime.fromMillisecondsSinceEpoch(message.dateSent! * 1000)),
          style: TextStyle(
              color: primaryColor, fontSize: 20.0, fontStyle: FontStyle.italic),
        ),
        margin: EdgeInsets.all(10.0),
      );
    }

    bool isHeaderView() {
      int headerId = int.parse(DateFormat('ddMMyyyy').format(
          DateTime.fromMillisecondsSinceEpoch(message.dateSent! * 1000)));
      if (index >= listMessage.length - 1) {
        return false;
      }
      var msgPrev = listMessage[index + 1];
      int nextItemHeaderId = int.parse(DateFormat('ddMMyyyy').format(
          DateTime.fromMillisecondsSinceEpoch(msgPrev.dateSent! * 1000)));
      var result = headerId != nextItemHeaderId;
      return result;
    }

    if (message.senderId == _cubeUser.id) {
      // Right (own message)
      return Column(
        children: <Widget>[
          isHeaderView() ? getHeaderDateWidget() : SizedBox.shrink(),
          Row(
            children: <Widget>[
              message.attachments?.isNotEmpty ?? false
                  // Image
                  ? Container(
                      child: TextButton(
                        child: Material(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                CachedNetworkImage(
                                  placeholder: (context, url) => Container(
                                    child: CircularProgressIndicator(
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          themeColor),
                                    ),
                                    width: 200.0,
                                    height: 200.0,
                                    padding: EdgeInsets.all(70.0),
                                    decoration: BoxDecoration(
                                      color: greyColor2,
                                      borderRadius: BorderRadius.all(
                                        Radius.circular(8.0),
                                      ),
                                    ),
                                  ),
                                  errorWidget: (context, url, error) =>
                                      Material(
                                    child: Image.asset(
                                      'images/img_not_available.jpeg',
                                      width: 200.0,
                                      height: 200.0,
                                      fit: BoxFit.cover,
                                    ),
                                    borderRadius: BorderRadius.all(
                                      Radius.circular(8.0),
                                    ),
                                    clipBehavior: Clip.hardEdge,
                                  ),
                                  imageUrl: message.attachments!.first.url!,
                                  width: 200.0,
                                  height: 200.0,
                                  fit: BoxFit.cover,
                                ),
                                getDateWidget(),
                                getReadDeliveredWidget(),
                              ]),
                          borderRadius: BorderRadius.all(Radius.circular(8.0)),
                          clipBehavior: Clip.hardEdge,
                        ),
                        onPressed: () {
                          Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (context) => FullPhoto(
                                      url: message.attachments!.first.url!)));
                        },
                      ),
                      margin: EdgeInsets.only(
                          bottom: isLastMessageRight(index) ? 20.0 : 10.0,
                          right: 10.0),
                    )
                  : message.body != null && message.body!.isNotEmpty
                      // Text
                      ? Flexible(
                          child: Container(
                            padding:
                                EdgeInsets.fromLTRB(15.0, 10.0, 15.0, 10.0),
                            decoration: BoxDecoration(
                                color: greyColor2,
                                borderRadius: BorderRadius.circular(8.0)),
                            margin: EdgeInsets.only(
                                bottom: isLastMessageRight(index) ? 20.0 : 10.0,
                                right: 10.0),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    message.body!,
                                    style: TextStyle(color: primaryColor),
                                  ),
                                  getDateWidget(),
                                  getReadDeliveredWidget(),
                                ]),
                          ),
                        )
                      : Container(
                          child: Text(
                            "Empty",
                            style: TextStyle(color: primaryColor),
                          ),
                          padding: EdgeInsets.fromLTRB(15.0, 10.0, 15.0, 10.0),
                          width: 200.0,
                          decoration: BoxDecoration(
                              color: greyColor2,
                              borderRadius: BorderRadius.circular(8.0)),
                          margin: EdgeInsets.only(
                              bottom: isLastMessageRight(index) ? 20.0 : 10.0,
                              right: 10.0),
                        ),
            ],
            mainAxisAlignment: MainAxisAlignment.end,
          ),
        ],
      );
    } else {
      // Left (opponent message)
      markAsReadIfNeed();
      return Container(
        child: Column(
          children: <Widget>[
            isHeaderView() ? getHeaderDateWidget() : SizedBox.shrink(),
            Row(
              children: <Widget>[
                Material(
                  child: CircleAvatar(
                    backgroundImage: _occupants[message.senderId]?.avatar !=
                                null &&
                            _occupants[message.senderId]!.avatar!.isNotEmpty
                        ? NetworkImage(_occupants[message.senderId]!.avatar!)
                        : null,
                    backgroundColor: greyColor2,
                    radius: 30,
                    child: getAvatarTextWidget(
                      _occupants[message.senderId]?.avatar != null &&
                          _occupants[message.senderId]!.avatar!.isNotEmpty,
                      _occupants[message.senderId]
                          ?.fullName
                          ?.substring(0, 2)
                          .toUpperCase(),
                    ),
                  ),
                  borderRadius: BorderRadius.all(
                    Radius.circular(18.0),
                  ),
                  clipBehavior: Clip.hardEdge,
                ),
                message.attachments?.isNotEmpty ?? false
                    ? Container(
                        child: TextButton(
                          child: Material(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  CachedNetworkImage(
                                    placeholder: (context, url) => Container(
                                      child: CircularProgressIndicator(
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                                themeColor),
                                      ),
                                      width: 200.0,
                                      height: 200.0,
                                      padding: EdgeInsets.all(70.0),
                                      decoration: BoxDecoration(
                                        color: greyColor2,
                                        borderRadius: BorderRadius.all(
                                          Radius.circular(8.0),
                                        ),
                                      ),
                                    ),
                                    errorWidget: (context, url, error) =>
                                        Material(
                                      child: Image.asset(
                                        'images/img_not_available.jpeg',
                                        width: 200.0,
                                        height: 200.0,
                                        fit: BoxFit.cover,
                                      ),
                                      borderRadius: BorderRadius.all(
                                        Radius.circular(8.0),
                                      ),
                                      clipBehavior: Clip.hardEdge,
                                    ),
                                    imageUrl: message.attachments!.first.url!,
                                    width: 200.0,
                                    height: 200.0,
                                    fit: BoxFit.cover,
                                  ),
                                  getDateWidget(),
                                ]),
                            borderRadius:
                                BorderRadius.all(Radius.circular(8.0)),
                            clipBehavior: Clip.hardEdge,
                          ),
                          onPressed: () {
                            Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) => FullPhoto(
                                        url: message.attachments!.first.url!)));
                          },
                        ),
                        margin: EdgeInsets.only(left: 10.0),
                      )
                    : message.body != null && message.body!.isNotEmpty
                        ? Flexible(
                            child: Container(
                              padding:
                                  EdgeInsets.fromLTRB(15.0, 10.0, 15.0, 10.0),
                              decoration: BoxDecoration(
                                  color: primaryColor,
                                  borderRadius: BorderRadius.circular(8.0)),
                              margin: EdgeInsets.only(left: 10.0),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      message.body!,
                                      style: TextStyle(color: Colors.white),
                                    ),
                                    getDateWidget(),
                                  ]),
                            ),
                          )
                        : Container(
                            child: Text(
                              "Empty",
                              style: TextStyle(color: primaryColor),
                            ),
                            padding:
                                EdgeInsets.fromLTRB(15.0, 10.0, 15.0, 10.0),
                            width: 200.0,
                            decoration: BoxDecoration(
                                color: greyColor2,
                                borderRadius: BorderRadius.circular(8.0)),
                            margin: EdgeInsets.only(
                                bottom: isLastMessageRight(index) ? 20.0 : 10.0,
                                right: 10.0),
                          ),
              ],
            ),
          ],
          crossAxisAlignment: CrossAxisAlignment.start,
        ),
        margin: EdgeInsets.only(bottom: 10.0),
      );
    }
  }

  bool isLastMessageLeft(int index) {
    if ((index > 0 && listMessage[index - 1].id == _cubeUser.id) ||
        index == 0) {
      return true;
    } else {
      return false;
    }
  }

  bool isLastMessageRight(int index) {
    if ((index > 0 && listMessage[index - 1].id != _cubeUser.id) ||
        index == 0) {
      return true;
    } else {
      return false;
    }
  }

  Widget buildLoading() {
    return Positioned(
      child: isLoading ? const Loading() : Container(),
    );
  }

  Widget buildTyping() {
    return Visibility(
      visible: isTyping,
      child: Container(
        child: Text(
          userStatus,
          style: TextStyle(color: primaryColor),
        ),
        alignment: Alignment.centerLeft,
        margin: EdgeInsets.all(16.0),
      ),
    );
  }

  Widget buildInput() {
    return Container(
      child: Row(
        children: <Widget>[
          // Button send image
          Material(
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: 1.0),
              child: IconButton(
                icon: Icon(Icons.image),
                onPressed: () {
                  openGallery();
                },
                color: primaryColor,
              ),
            ),
            color: Colors.white,
          ),

          // Edit text
          Flexible(
            child: Container(
              child: TextField(
                style: TextStyle(color: primaryColor, fontSize: 15.0),
                controller: textEditingController,
                decoration: InputDecoration.collapsed(
                  hintText: 'Type your message...',
                  hintStyle: TextStyle(color: greyColor),
                ),
                onChanged: (text) {
                  sendIsTypingStatus();
                },
              ),
            ),
          ),

          // Button send message
          Material(
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: 8.0),
              child: IconButton(
                icon: Icon(Icons.send),
                onPressed: () => onSendChatMessage(textEditingController.text),
                color: primaryColor,
              ),
            ),
            color: Colors.white,
          ),
        ],
      ),
      width: double.infinity,
      height: 50.0,
      decoration: BoxDecoration(
          border: Border(top: BorderSide(color: greyColor2, width: 0.5)),
          color: Colors.white),
    );
  }

  Widget buildListMessage() {
    getWidgetMessages(listMessage) {
      return ListView.builder(
        padding: EdgeInsets.all(10.0),
        itemBuilder: (context, index) => buildItem(index, listMessage[index]),
        itemCount: listMessage.length,
        reverse: true,
        controller: listScrollController,
      );
    }

    return Flexible(
      child: StreamBuilder<List<CubeMessage>>(
        stream: getMessagesList().asStream(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(
                child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(themeColor)));
          } else {
            listMessage = snapshot.data ?? [];
            return getWidgetMessages(listMessage);
          }
        },
      ),
    );
  }

  Future<List<CubeMessage>> getMessagesList() async {
    if (listMessage.isNotEmpty) return Future.value(listMessage);

    Completer<List<CubeMessage>> completer = Completer();
    List<CubeMessage>? messages;
    try {
      await Future.wait<void>([
        getMessagesByDate(0, false).then((loadedMessages) {
          isLoading = false;
          messages = loadedMessages;
        }),
        getAllUsersByIds(_cubeDialog.occupantsIds!.toSet()).then((result) =>
            _occupants.addAll(Map.fromIterable(result!.items,
                key: (item) => item.id, value: (item) => item)))
      ]);
      completer.complete(messages);
    } catch (error) {
      completer.completeError(error);
    }
    return completer.future;
  }

  void onScrollChanged() {
    if ((listScrollController.position.pixels ==
            listScrollController.position.maxScrollExtent) &&
        messagesPerPage >= lastPartSize) {
      setState(() {
        isLoading = true;

        if (oldMessages.isNotEmpty) {
          getMessagesBetweenDates(
                  oldMessages.first.dateSent ?? 0,
                  listMessage.last.dateSent ??
                      DateTime.now().millisecondsSinceEpoch ~/ 1000)
              .then((newMessages) {
            setState(() {
              isLoading = false;

              listMessage.addAll(newMessages);

              if (newMessages.length < messagesPerPage) {
                oldMessages.insertAll(0, listMessage);
                listMessage = List.from(oldMessages);
                oldMessages.clear();
              }
            });
          });
        } else {
          getMessagesByDate(listMessage.last.dateSent ?? 0, false)
              .then((messages) {
            setState(() {
              isLoading = false;
              listMessage.addAll(messages);
            });
          });
        }
      });
    }
  }

  Future<bool> onBackPress() {
    Navigator.pushNamedAndRemoveUntil(context, 'select_dialog', (r) => false,
        arguments: {USER_ARG_NAME: _cubeUser});

    return Future.value(false);
  }

  _initChatListeners() {
    log("[_initChatListeners]");
    msgSubscription = CubeChatConnection
        .instance.chatMessagesManager!.chatMessagesStream
        .listen(onReceiveMessage);
    deliveredSubscription = CubeChatConnection
        .instance.messagesStatusesManager!.deliveredStream
        .listen(onDeliveredMessage);
    readSubscription = CubeChatConnection
        .instance.messagesStatusesManager!.readStream
        .listen(onReadMessage);
    typingSubscription = CubeChatConnection
        .instance.typingStatusesManager!.isTypingStream
        .listen(onTypingMessage);
  }

  void _initCubeChat() {
    log("_initCubeChat");
    if (CubeChatConnection.instance.isAuthenticated()) {
      log("[_initCubeChat] isAuthenticated");
      _initChatListeners();
    } else {
      log("[_initCubeChat] not authenticated");
      CubeChatConnection.instance.connectionStateStream.listen((state) {
        log("[_initCubeChat] state $state");
        if (CubeChatConnectionState.Ready == state) {
          _initChatListeners();

          if (_unreadMessages.isNotEmpty) {
            _unreadMessages.forEach((cubeMessage) {
              _cubeDialog.readMessage(cubeMessage);
            });
            _unreadMessages.clear();
          }

          if (_unsentMessages.isNotEmpty) {
            _unsentMessages.forEach((cubeMessage) {
              _cubeDialog.sendMessage(cubeMessage);
            });

            _unsentMessages.clear();
          }
        }
      });
    }
  }

  void sendIsTypingStatus() {
    var currentTime = DateTime.now().millisecondsSinceEpoch;
    var isTypingTimeout = currentTime - _sendIsTypingTime;
    if (isTypingTimeout >= TYPING_TIMEOUT) {
      _sendIsTypingTime = currentTime;
      _cubeDialog.sendIsTypingStatus();
      _startStopTypingStatus();
    }
  }

  void _startStopTypingStatus() {
    _sendStopTypingTimer?.cancel();
    _sendStopTypingTimer =
        Timer(Duration(milliseconds: STOP_TYPING_TIMEOUT), () {
      _cubeDialog.sendStopTypingStatus();
    });
  }

  Future<List<CubeMessage>> getMessagesByDate(int date, bool isLoadNew) async {
    var params = GetMessagesParameters();
    params.sorter = RequestSorter(SORT_DESC, '', 'date_sent');
    params.limit = messagesPerPage;
    params.filters = [
      RequestFilter('', 'date_sent', isLoadNew || date == 0 ? 'gt' : 'lt', date)
    ];

    return getMessages(_cubeDialog.dialogId!, params.getRequestParameters())
        .then((result) {
          lastPartSize = result!.items.length;

          return result.items;
        })
        .whenComplete(() {})
        .catchError((onError) {});
  }

  Future<List<CubeMessage>> getMessagesBetweenDates(
      int startDate, int endDate) async {
    var params = GetMessagesParameters();
    params.sorter = RequestSorter(SORT_DESC, '', 'date_sent');
    params.limit = messagesPerPage;
    params.filters = [
      RequestFilter('', 'date_sent', 'gt', startDate),
      RequestFilter('', 'date_sent', 'lt', endDate)
    ];

    return getMessages(_cubeDialog.dialogId!, params.getRequestParameters())
        .then((result) {
      return result!.items;
    });
  }

  void onConnectivityChanged(ConnectivityResult connectivityType) {
    log("[ChatScreenState] connectivityType changed to '$connectivityType'");

    if (connectivityType == ConnectivityResult.wifi ||
        connectivityType == ConnectivityResult.mobile) {
      setState(() {
        isLoading = true;
      });

      getMessagesBetweenDates(listMessage.first.dateSent ?? 0,
              DateTime.now().millisecondsSinceEpoch ~/ 1000)
          .then((newMessages) {
        setState(() {
          if (newMessages.length == messagesPerPage) {
            oldMessages = List.from(listMessage);
            listMessage = newMessages;
          } else {
            listMessage.insertAll(0, newMessages);
          }
        });
      }).whenComplete(() {
        setState(() {
          isLoading = false;
        });
      });
    }
  }
}
