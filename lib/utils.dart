
import 'dart:io';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as path;
import 'package:real_esrgan_gui/components/io_form.dart';

/// 拡大アルゴリズムの種類
enum UpscaleAlgorithmType {
  RealESRGAN,
  RealCUGAN,
}

/// 処理プロファイル
enum ProcessingProfile {
  balanced,
  speed,
  quality,
}

/// 出力先フォルダの既存時挙動
enum OutputFolderBehavior {
  createNew,
  appendOverwrite,
  recreate,
}

/// アップスケール処理時の実行オプション
class UpscaleRuntimeOptions {
  UpscaleRuntimeOptions({
    required this.profile,
    required this.loadThreadCount,
    required this.procThreadCount,
    required this.saveThreadCount,
    required this.tileSize,
    required this.enableTTAMode,
  });

  ProcessingProfile profile;
  int loadThreadCount;
  int procThreadCount;
  int saveThreadCount;
  int tileSize;
  bool enableTTAMode;

  /// ncnn-vulkan の -j 引数向けにスレッド設定を組み立てる
  String get threadOption => '${loadThreadCount}:${procThreadCount}:${saveThreadCount}';

  /// プリセットに応じた実行オプションを生成する
  static UpscaleRuntimeOptions fromProfile({
    required ProcessingProfile profile,
    required bool supportsTTA,
  }) {
    switch (profile) {
      case ProcessingProfile.speed:
        return UpscaleRuntimeOptions(
          profile: profile,
          loadThreadCount: 2,
          procThreadCount: 4,
          saveThreadCount: 2,
          tileSize: 0,
          enableTTAMode: false,
        );
      case ProcessingProfile.quality:
        return UpscaleRuntimeOptions(
          profile: profile,
          loadThreadCount: 1,
          procThreadCount: 2,
          saveThreadCount: 1,
          tileSize: 200,
          enableTTAMode: supportsTTA,
        );
      case ProcessingProfile.balanced:
      default:
        return UpscaleRuntimeOptions(
          profile: profile,
          loadThreadCount: 1,
          procThreadCount: 2,
          saveThreadCount: 2,
          tileSize: 0,
          enableTTAMode: false,
        );
    }
  }
}

/// 拡大アルゴリズムの実行ファイルのパスを取得する
String getUpscaleAlgorithmExecutablePath(UpscaleAlgorithmType upscaleAlgorithmType) {

  // assets/ フォルダへの絶対パスを取得する
  // 実行ファイルを実行するためには、必然的に assets/ 以下への絶対パスを取得する必要があるため
  var assetsDirectoryPath = '';
  if (Platform.isWindows) {
    // Windows: Real-ESRGAN-GUI/data/flutter_assets/assets/
    assetsDirectoryPath = path.join(
      path.dirname(Platform.resolvedExecutable),
      'data/flutter_assets/assets/',
    );
  } else if (Platform.isMacOS) {
    // macOS: Real-ESRGAN-GUI.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/
    assetsDirectoryPath = path.join(
      path.dirname(Platform.resolvedExecutable).replaceAll('MacOS', ''),
      'Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/',
    );
  }

  // Windows でのみ .exe の拡張子をつける
  var extension = '';
  if (Platform.isWindows) extension = '.exe';

  switch (upscaleAlgorithmType) {
    case UpscaleAlgorithmType.RealESRGAN:
      return path.join(assetsDirectoryPath, 'realesrgan-ncnn-vulkan/realesrgan-ncnn-vulkan${extension}');
    case UpscaleAlgorithmType.RealCUGAN:
      return path.join(assetsDirectoryPath, 'realcugan-ncnn-vulkan/realcugan-ncnn-vulkan${extension}');
    default:
      return '';
  }
}

/// 入出力フォームのバリデーションを行う
Future<bool> validateIOForm({
  required BuildContext context,
  required IOFormMode ioFormMode,
  required TextEditingController inputFileController,
  required TextEditingController outputFileController,
  required TextEditingController inputFolderController,
  required TextEditingController outputFolderController,
  required OutputFolderBehavior outputFolderBehavior,
}) async {

  // バリデーション (ファイル選択モード)
  if (ioFormMode == IOFormMode.fileSelection) {

    // 入力元ファイルが指定されていない
    if (inputFileController.text == '') {
      showSnackBar(context: context, content: const Text('message.noInputFile').tr());
      return false;
    }

    // 出力先ファイルが指定されていない
    if (outputFileController.text == '') {
      showSnackBar(context: context, content: const Text('message.noOutputFilePath').tr());
      return false;
    }

    // 不正なファイルパスでないかの確認
    try {
      await Directory(path.dirname(outputFileController.text)).exists();
    } on FileSystemException {
      showSnackBar(context: context, content: const Text('message.invalidOutputFilePath').tr());
      return false;
    }

    // 出力先ファイルが既に存在する場合
    // 上書きするかの確認を取る
    if (await File(outputFileController.text).exists()) {
      var overwrite = false;
      await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (_) {
          return AlertDialog(
            title: const Text('label.overwriteConfirm').tr(),
            content: const Text('message.overwriteFileConfirm').tr(args: [outputFileController.text]),
            actionsPadding: const EdgeInsets.only(right: 12, bottom: 12),
            actions: [
              TextButton(
                child: const Text('label.cancel').tr(),
                onPressed: () => Navigator.pop(context),
              ),
              TextButton(
                child: const Text('label.overwriteFile').tr(),
                onPressed: () {
                  overwrite = true;
                  Navigator.pop(context);
                }
              ),
            ],
          );
        },
      );
      // キャンセルされたら実行しない
      if (overwrite == false) return false;
    }

  // バリデーション (フォルダ選択モード)
  } else if (ioFormMode == IOFormMode.folderSelection) {

    // 入力元フォルダが指定されていない
    if (inputFolderController.text == '') {
      showSnackBar(context: context, content: const Text('message.noInputFolder').tr());
      return false;
    }

    // 出力先ファイルが指定されていない
    if (outputFolderController.text == '') {
      showSnackBar(context: context, content: const Text('message.noOutputFolderPath').tr());
      return false;
    }

    // 不正なフォルダパスでないかの確認
    try {
      await Directory(outputFolderController.text).exists();
    } on FileSystemException {
      showSnackBar(context: context, content: const Text('message.invalidOutputFolderPath').tr());
      return false;
    }

    // 出力先フォルダが既に存在する場合
    // 上書きするかの確認を取る
    if (await Directory(outputFolderController.text).exists() && outputFolderBehavior == OutputFolderBehavior.recreate) {
      var overwrite = false;
      var overwriteSecondConfirm = false;
      await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (_) {
          return AlertDialog(
            title: const Text('label.overwriteConfirm').tr(),
            content: const Text('message.overwriteFolderConfirm').tr(args: [outputFolderController.text]),
            actionsPadding: const EdgeInsets.only(right: 12, bottom: 12),
            actions: [
              TextButton(
                child: const Text('label.cancel').tr(),
                onPressed: () => Navigator.pop(context),
              ),
              TextButton(
                child: const Text('label.overwriteFolder').tr(),
                onPressed: () {
                  overwrite = true;
                  Navigator.pop(context);
                }
              ),
            ],
          );
        },
      );
      if (overwrite) {
        await showDialog(
          context: context,
          barrierDismissible: true,
          builder: (_) {
            return AlertDialog(
              title: const Text('label.overwriteConfirm').tr(),
              content: const Text('message.overwriteFolderConfirm').tr(args: ['${outputFolderController.text}\n(DELETE & RECREATE)']),
              actionsPadding: const EdgeInsets.only(right: 12, bottom: 12),
              actions: [
                TextButton(
                  child: const Text('label.cancel').tr(),
                  onPressed: () => Navigator.pop(context),
                ),
                TextButton(
                  child: const Text('label.overwriteFolder').tr(),
                  onPressed: () {
                    overwriteSecondConfirm = true;
                    Navigator.pop(context);
                  },
                ),
              ],
            );
          },
        );
      }
      // キャンセルされたら実行しない
      if (!overwriteSecondConfirm) return false;
    }

    if (await Directory(outputFolderController.text).exists() && outputFolderBehavior == OutputFolderBehavior.appendOverwrite) {
      var overwrite = false;
      await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (_) {
          return AlertDialog(
            title: const Text('label.overwriteConfirm').tr(),
            content: const Text('message.overwriteFolderConfirm').tr(args: [outputFolderController.text]),
            actionsPadding: const EdgeInsets.only(right: 12, bottom: 12),
            actions: [
              TextButton(
                child: const Text('label.cancel').tr(),
                onPressed: () => Navigator.pop(context),
              ),
              TextButton(
                child: const Text('label.overwriteFolder').tr(),
                onPressed: () {
                  overwrite = true;
                  Navigator.pop(context);
                }
              ),
            ],
          );
        },
      );
      if (overwrite == false) return false;
    }
  }

  // ここまでのバリデーションをすべて通過したときだけ true を返す
  return true;
}

/// 処理対象の画像ファイルのパスのリスト
/// 戻り値は入力ファイルと出力ファイルのペアの配列
Future<List<Map<String, String>>> getInputFileWithOutputFilePairList({
  required BuildContext context,
  required IOFormMode ioFormMode,
  required String outputFormat,
  required TextEditingController inputFileController,
  required TextEditingController outputFileController,
  required TextEditingController inputFolderController,
  required TextEditingController outputFolderController,
  required OutputFolderBehavior outputFolderBehavior,
}) async {

  List<Map<String, String>> imageFiles = [];

  // ファイル選択モードでは、選択されたファイル1つだけを追加する
  if (ioFormMode == IOFormMode.fileSelection) {

    // 入力元ファイルと出力先ファイルをセットで追加
    // 出力先ファイルにはフォームの値を使う
    imageFiles.add({'input': inputFileController.text, 'output': outputFileController.text});

    // 出力先ファイルが保存されるフォルダを作成 (すでにある場合は何もしない)
    await Directory(path.dirname(outputFileController.text)).create(recursive: true);

  // フォルダ選択モードでは、選択されたフォルダ以下の画像ファイル（1階層のみ）すべてを追加する
  } else if (ioFormMode == IOFormMode.folderSelection) {

    var outputRootDirectoryPath = outputFolderController.text;
    var outputDirectory = Directory(outputFolderController.text);

    // 出力先フォルダの既存時挙動を反映
    if (await outputDirectory.exists()) {
      switch (outputFolderBehavior) {
        case OutputFolderBehavior.createNew:
          outputRootDirectoryPath = await _createUniqueOutputDirectoryPath(outputFolderController.text);
          outputFolderController.text = outputRootDirectoryPath;
          break;
        case OutputFolderBehavior.recreate:
          await outputDirectory.delete(recursive: true);
          break;
        case OutputFolderBehavior.appendOverwrite:
          break;
      }
    }

    // 画像ファイルのみを Glob で取得
    var glob = Glob('{**.jpg,**.jpeg,**.png,**.webp}');
    for (var file in glob.listSync(root: inputFolderController.text)) {

      // 出力先のファイルパスを生成
      var outputFilePath = path.normalize(path.join(
        // 出力先のフォルダパスフォームの値
        outputRootDirectoryPath,
        // 拡大元の画像ファイルのフォルダ名 (選択されたフォルダからの相対パス)
        path.relative(path.dirname(file.path), from: inputFolderController.text),
        // 入力元ファイルの拡張子なしファイル名 + 保存形式 (jpg / png / webp)
        '${path.basenameWithoutExtension(file.path)}.${outputFormat}',
      ));

      // 入力元ファイルと出力先ファイルをセットで追加
      imageFiles.add({'input': file.path, 'output': outputFilePath});
    }

    // 指定されたフォルダにひとつも画像ファイルが見つからなかった場合、エラーを出して終了
    if (ioFormMode == IOFormMode.folderSelection && imageFiles.isEmpty) {
      showSnackBar(context: context, content: const Text('message.noImageFilesInFolder').tr());
      return [];  // 空の配列を返す
    }

    // 出力先フォルダを作成 (すでにある場合は何もしない)
    await Directory(outputRootDirectoryPath).create(recursive: true);
  }

  return imageFiles;
}

Future<String> _createUniqueOutputDirectoryPath(String basePath) async {
  var dateTime = DateTime.now();
  var timestamp = '${dateTime.year.toString().padLeft(4, '0')}'
      '${dateTime.month.toString().padLeft(2, '0')}'
      '${dateTime.day.toString().padLeft(2, '0')}-'
      '${dateTime.hour.toString().padLeft(2, '0')}'
      '${dateTime.minute.toString().padLeft(2, '0')}'
      '${dateTime.second.toString().padLeft(2, '0')}';
  var candidate = '${basePath}-${timestamp}';
  var serial = 1;
  while (await Directory(candidate).exists()) {
    candidate = '${basePath}-${timestamp}-${serial++}';
  }
  return candidate;
}

/// 簡単に SnackBar を表示する
void showSnackBar({required BuildContext context, required Widget content, Duration? duration}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: content,
    duration: duration ?? const Duration(milliseconds: 4000),
    action: SnackBarAction(
      label: 'label.close'.tr(),
      onPressed: () {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      },
    ),
  ));
}
