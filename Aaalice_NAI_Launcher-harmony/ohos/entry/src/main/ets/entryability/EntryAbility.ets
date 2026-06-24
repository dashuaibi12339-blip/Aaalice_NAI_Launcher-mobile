import { AbilityConstant, Want } from '@kit.AbilityKit';
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import MethodChannel, { MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';
import fs from '@ohos.file.fs';
import { systemShare } from '@kit.ShareKit';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';

// 🌟 新增：导入后台任务管理器
import backgroundTaskManager from '@ohos.backgroundTaskManager';

export default class EntryAbility extends FlutterAbility {
  private shareChannel: MethodChannel | null = null;
  private pendingShareData: Array<string> = [];
  
  // 🌟 新增：记录保活任务的 ID
  private suspendId: number = 0;

  override configureFlutterEngine(flutterEngine: FlutterEngine): void {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);

    this.shareChannel = new MethodChannel(flutterEngine.dartExecutor.getBinaryMessenger(), "com.nai.launcher/share");
    
    this.shareChannel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        if (call.method === "getPendingShareData") {
          result.success(this.pendingShareData);
          this.pendingShareData = []; 
        } else {
          result.notImplemented();
        }
      }
    });
  }

  override onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onCreate(want, launchParam);
    this.handleShareWant(want);
    this.context.eventHub.on("onSuperHubDrop", (sharedItems: Array<string>) => {
      if (this.shareChannel !== null) {
        this.shareChannel.invokeMethod("onSharedData", sharedItems);
      } else {
        for (let i = 0; i < sharedItems.length; i++) {
          this.pendingShareData.push(sharedItems[i]);
        }
      }
    });
  }

  override onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onNewWant(want, launchParam);
    this.handleShareWant(want);
  }

  // ==========================================
  // 🌟 新增：后台保活生命周期（切到桌面时触发）
  // ==========================================
  onBackground(): void {
    super.onBackground();
    try {
      // 向系统借 3 分钟的满血运行时间
      let delayInfo = backgroundTaskManager.requestSuspendDelay("image_generation", () => {
        console.info("后台保活时间已用尽");
      });
      this.suspendId = delayInfo.requestId;
      console.info("成功申请后台保活，ID: " + this.suspendId);
    } catch (error) {
      console.error("后台保活申请失败: " + error);
    }
  }

  // ==========================================
  // 🌟 新增：前台恢复生命周期（回到应用时触发）
  // ==========================================
  onForeground(): void {
    super.onForeground();
    // 回到前台后，把时间还给系统，避免被系统判定为流氓软件
    if (this.suspendId !== 0) {
      try {
        backgroundTaskManager.cancelSuspendDelay(this.suspendId);
        console.info("已取消后台保活");
      } catch (error) {
        console.error("取消后台保活失败: " + error);
      }
      this.suspendId = 0;
    }
  }

  private async handleShareWant(want: Want): Promise<void> {
    if (want.action === "ohos.want.action.sendData" || want.action === "ohos.want.action.sendMultipleData") {
      let sharedItems: Array<string> = [];
      let urisToProcess: Array<string> = [];
      let textContent = "";

      try {
        let sharedData = await systemShare.getSharedData(want);
        if (sharedData) {
          let records = sharedData.getRecords();
          for (let i = 0; i < records.length; i++) {
            let record = records[i];
            if (record.utd.includes('text') || record.utd.includes('hyperlink')) {
              if (record.content && record.content.trim() !== "") {
                textContent = record.content.trim();
                break;
              }
            } else if (record.uri) {
              urisToProcess.push(record.uri);
            }
          }
        }
      } catch (e) {
        console.warn("ShareKit 解析失败或非 ShareKit 发起: " + e);
      }

      if (textContent === "") {
        if (want.parameters) {
          let params = want.parameters as Record<string, Object>;
          let textKeys = [
            'ability.want.params.CONTENT',
            'ability.params.text',
            'ohos.extra.TEXT',
            'share_text',
            'text',
            'content'
          ];
          for (let i = 0; i < textKeys.length; i++) {
            let val = params[textKeys[i]];
            if (val !== undefined && val !== null) {
              if (typeof val === 'string' && val.trim() !== "") {
                textContent = val.trim();
                break;
              }
            }
          }
        }
      }

      if (want.uri && urisToProcess.length === 0 && textContent === "") {
        let uriStr = want.uri.trim();
        if (uriStr.startsWith("http://") || uriStr.startsWith("https://")) {
          textContent = uriStr;
        } else if (uriStr.startsWith("file://") || uriStr.startsWith("datashare://") || uriStr.startsWith("content://")) {
          urisToProcess.push(uriStr);
        }
      }

      if (textContent !== "") {
        if (textContent.startsWith("http://") || textContent.startsWith("https://")) {
          sharedItems.push("url:" + textContent);
        } else {
          sharedItems.push("text:" + textContent);
        }
      }

      for (let i = 0; i < urisToProcess.length; i++) {
        let uri = urisToProcess[i];
        try {
          let originalName = uri.split('/').pop() || "file";
          let extIndex = originalName.lastIndexOf('.');
          let ext = extIndex !== -1 ? originalName.substring(extIndex) : "";
          let tempFileName = `shared_${Date.now()}_${Math.floor(Math.random() * 1000)}${ext}`;
          let tempFilePath = this.context.cacheDir + '/' + tempFileName;

          let file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
          fs.copyFileSync(file.fd, tempFilePath); 
          fs.closeSync(file);

          sharedItems.push("file:" + tempFilePath);
        } catch (e) {
          console.error("Failed to process uri: " + uri);
        }
      }

      let uniqueItems = Array.from(new Set(sharedItems));

      if (uniqueItems.length > 0) {
        if (this.shareChannel !== null) {
          this.shareChannel.invokeMethod("onSharedData", uniqueItems);
        } else {
          for (let i = 0; i < uniqueItems.length; i++) {
            this.pendingShareData.push(uniqueItems[i]);
          }
        }
      } else {
        if (this.shareChannel !== null) {
          this.shareChannel.invokeMethod("onSharedData", ["text:【无法识别的分享格式】\n请尝试复制后手动粘贴。"]);
        }
      }
    }
  }
}