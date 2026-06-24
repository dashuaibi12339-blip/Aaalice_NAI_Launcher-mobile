import common from '@ohos.app.ability.common';
import { FlutterPage } from '@ohos/flutter_ohos';

// 引入拖拽数据与文件系统需要的模块
import { unifiedDataChannel, uniformTypeDescriptor } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';

let storage = LocalStorage.getShared()
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS'

@Entry(storage)
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext
  @LocalStorageLink('viewId') viewId: string = "";

  build() {
    // 🌟 核心修复 1：改用 Stack 层叠布局
    Stack() {
      // 第一层（底层）：Flutter 渲染引擎，负责显示 App 画面
      FlutterPage({ viewId: this.viewId })

      // 第二层（顶层）：全透明的拖拽拦截网
      Column()
        .width('100%')
        .height('100%')
        // 🌟 核心修复 2：事件穿透！让这层网只抓拖拽，普通点击完美穿透给 Flutter！
        .hitTestBehavior(HitTestMode.Transparent)
        .allowDrop([
          uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
          uniformTypeDescriptor.UniformDataType.HYPERLINK,
          uniformTypeDescriptor.UniformDataType.IMAGE,
          uniformTypeDescriptor.UniformDataType.FILE,
          uniformTypeDescriptor.UniformDataType.VIDEO
        ])
        // 🌟 核心修复 3：必须在拖拽进入和移动时告诉系统“可以放下”，才会出现绿色的 + 号！
        .onDragEnter((event: DragEvent) => {
          event.setResult(DragResult.DROP_ENABLED);
          event.dragBehavior = DragBehavior.COPY; // 强制显示复制图标(+)
        })
        .onDragMove((event: DragEvent) => {
          event.setResult(DragResult.DROP_ENABLED);
          event.dragBehavior = DragBehavior.COPY;
        })
        .onDrop((event: DragEvent) => {
          let unifiedData = event.getData();
          if (!unifiedData) {
            event.setResult(DragResult.DRAG_FAILED);
            return;
          }

          let records = unifiedData.getRecords();
          let sharedItems: Array<string> = [];

          for (let i = 0; i < records.length; i++) {
            let record = records[i];
            let type = record.getType();

            // 1. 文本
            if (type === uniformTypeDescriptor.UniformDataType.PLAIN_TEXT) {
              let textRecord = record as unifiedDataChannel.PlainText;
              if (textRecord.textContent) {
                sharedItems.push("text:" + textRecord.textContent);
              }
            } 
            // 2. 链接
            else if (type === uniformTypeDescriptor.UniformDataType.HYPERLINK) {
              let linkRecord = record as unifiedDataChannel.Hyperlink;
              if (linkRecord.url) {
                sharedItems.push("url:" + linkRecord.url);
              }
            } 
            // 3. 文件或图片（兜底所有二进制文件）
            else {
              let fileRecord = record as unifiedDataChannel.File;
              if (fileRecord && fileRecord.uri) {
                let uri = fileRecord.uri;
                try {
                  let originalName = uri.split('/').pop() || "file";
                  let extIndex = originalName.lastIndexOf('.');
                  let ext = extIndex !== -1 ? originalName.substring(extIndex) : "";
                  let tempFileName = `drop_${Date.now()}_${Math.floor(Math.random() * 1000)}${ext}`;
                  let tempFilePath = this.context.cacheDir + '/' + tempFileName;

                  let file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
                  fs.copyFileSync(file.fd, tempFilePath);
                  fs.closeSync(file);

                  sharedItems.push("file:" + tempFilePath);
                } catch (e) {
                  console.error("Drop file copy failed: " + e);
                }
              }
            }
          }

          // 提取完毕后，直接发送给 EntryAbility，唤醒 Flutter
          if (sharedItems.length > 0) {
            this.context.eventHub.emit("onSuperHubDrop", sharedItems);
            // 告诉系统中转站“拖拽已成功”，执行飞入动画
            event.setResult(DragResult.DRAG_SUCCESSFUL);
          } else {
            event.setResult(DragResult.DRAG_FAILED);
          }
        })
    }
    .width('100%')
    .height('100%')
  }

  onBackPress(): boolean {
    this.context.eventHub.emit(EVENT_BACK_PRESS)
    return true
  }
}