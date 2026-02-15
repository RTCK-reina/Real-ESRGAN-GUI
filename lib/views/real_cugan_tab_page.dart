import 'dart:convert';
import 'dart:io';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:real_esrgan_gui/components/denoise_level_dropdown.dart';
import 'package:real_esrgan_gui/components/io_form.dart';
import 'package:real_esrgan_gui/components/model_type_dropdown.dart';
import 'package:real_esrgan_gui/components/output_format_dropdown.dart';
import 'package:real_esrgan_gui/components/processing_profile_dropdown.dart';
import 'package:real_esrgan_gui/components/start_button_and_progress_bar.dart';
import 'package:real_esrgan_gui/components/upscale_ratio_dropdown.dart';
import 'package:real_esrgan_gui/utils.dart';

class RealCUGANTabPage extends StatefulWidget {
  const RealCUGANTabPage({super.key});

  @override
  State<RealCUGANTabPage> createState() => RealCUGANTabPageState();
}

class RealCUGANTabPageState extends State<RealCUGANTabPage> {
  IOFormMode ioFormMode = IOFormMode.fileSelection;
  TextEditingController inputFileController = TextEditingController();
  TextEditingController outputFileController = TextEditingController();
  TextEditingController inputFolderController = TextEditingController();
  TextEditingController outputFolderController = TextEditingController();

  String modelType = 'models-pro';
  DenoiseLevel denoiseLevel = DenoiseLevel.conservative;
  String upscaleRatio = '2x';
  String outputFormat = 'jpg';
  ProcessingProfile processingProfile = ProcessingProfile.balanced;
  OutputFolderBehavior outputFolderBehavior = OutputFolderBehavior.createNew;
  int tileSize = 0;
  final TextEditingController tileSizeController = TextEditingController(text: '0');

  double? progressPercentage = 0;
  bool isProcessing = false;
  bool isCancelRequested = false;
  Process? process;
  String latestStdoutLog = '';
  String latestStderrLog = '';

  Future<void> cancelUpscaleProcess() async {
    setState(() {
      isCancelRequested = true;
      isProcessing = false;
      progressPercentage = 0;
    });
    process?.kill(ProcessSignal.sigterm);
  }

  Future<void> upscaleImage() async {
    if (isProcessing) {
      await cancelUpscaleProcess();
      return;
    }

    var validateResult = await validateIOForm(
      context: context,
      ioFormMode: ioFormMode,
      inputFileController: inputFileController,
      outputFileController: outputFileController,
      inputFolderController: inputFolderController,
      outputFolderController: outputFolderController,
      outputFolderBehavior: outputFolderBehavior,
    );
    if (!validateResult) return;

    List<Map<String, String>> imageFiles = await getInputFileWithOutputFilePairList(
      context: context,
      ioFormMode: ioFormMode,
      outputFormat: outputFormat,
      inputFileController: inputFileController,
      outputFileController: outputFileController,
      inputFolderController: inputFolderController,
      outputFolderController: outputFolderController,
      outputFolderBehavior: outputFolderBehavior,
    );
    if (imageFiles.isEmpty) return;

    var progressStep = 100 / imageFiles.length;
    setState(() {
      progressPercentage = ioFormMode == IOFormMode.fileSelection ? null : progressStep * 0.1;
      isCancelRequested = false;
      isProcessing = true;
      latestStdoutLog = '';
      latestStderrLog = '';
    });

    for (var progressIndex = 0; progressIndex < imageFiles.length; progressIndex++) {
      if (isCancelRequested) break;
      var executablePath = getUpscaleAlgorithmExecutablePath(UpscaleAlgorithmType.RealCUGAN);

      String denoiseLevelArg;
      switch (denoiseLevel) {
        case DenoiseLevel.conservative:
          denoiseLevelArg = '-1';
          break;
        case DenoiseLevel.none:
          denoiseLevelArg = '0';
          break;
        case DenoiseLevel.denoise1x:
          denoiseLevelArg = '1';
          break;
        case DenoiseLevel.denoise2x:
          denoiseLevelArg = '2';
          break;
        case DenoiseLevel.denoise3x:
          denoiseLevelArg = '3';
          break;
      }

      var runtimeOptions = UpscaleRuntimeOptions.fromProfile(profile: processingProfile, supportsTTA: false);

      try {
        process = await Process.start(executablePath, [
          '-i', imageFiles[progressIndex]['input']!,
          '-o', imageFiles[progressIndex]['output']!,
          '-m', modelType,
          '-n', denoiseLevelArg,
          '-s', upscaleRatio.replaceAll('x', ''),
          '-f', outputFormat,
          '-j', runtimeOptions.threadOption,
          if (tileSize > 0) ...['-t', tileSize.toString()],
        ], workingDirectory: path.dirname(executablePath));
      } on ProcessException catch (error) {
        setState(() {
          isProcessing = false;
          progressPercentage = 0;
        });
        showSnackBar(context: context, content: SelectableText('Process start failed: ${error.message}'));
        return;
      }

      final stdoutLines = <String>[];
      final stderrLines = <String>[];
      process!.stdout.transform(utf8.decoder).listen((line) => stdoutLines.add(line));
      process!.stderr.transform(utf8.decoder).listen((line) => stderrLines.add(line));

      var exitCode = await process!.exitCode;
      latestStdoutLog += stdoutLines.join('');
      latestStderrLog += stderrLines.join('');

      if (isCancelRequested) break;

      if (exitCode != 0) {
        setState(() {
          isProcessing = false;
          progressPercentage = 0;
        });
        await showProcessLogDialog('Process execution failed (exit code: $exitCode).');
        return;
      }

      setState(() {
        progressPercentage = progressStep * (progressIndex + 1);
      });
    }

    if (isCancelRequested) {
      showSnackBar(context: context, content: const Text('message.canceled').tr());
    } else {
      showSnackBar(context: context, content: const Text('message.completed').tr());
    }

    setState(() {
      progressPercentage = 0;
      isProcessing = false;
    });
  }

  Future<void> showProcessLogDialog(String title) async {
    final allLogs = 'STDOUT\n$latestStdoutLog\n\nSTDERR\n$latestStderrLog';
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(child: SelectableText(allLogs.isEmpty ? 'No logs' : allLogs)),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: allLogs));
            },
            child: const Text('Copy Logs'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData(
        primarySwatch: Colors.lightBlue,
        fontFamily: 'M PLUS 2',
        snackBarTheme: const SnackBarThemeData(contentTextStyle: TextStyle(fontFamily: 'M PLUS 2')),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4, left: 24, right: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                IOFormWidget(
                  inputFileController: inputFileController,
                  outputFileController: outputFileController,
                  inputFolderController: inputFolderController,
                  outputFolderController: outputFolderController,
                  upscaleRatio: upscaleRatio,
                  outputFormat: outputFormat,
                  onModeChanged: (ioFormMode) => setState(() => this.ioFormMode = ioFormMode),
                  onOutputFormatChanged: (outputFormat) => setState(() => this.outputFormat = outputFormat),
                ),
                const SizedBox(height: 20),
                ModelTypeDropdownWidget(
                  upscaleAlgorithmType: UpscaleAlgorithmType.RealCUGAN,
                  modelType: modelType,
                  modelTypeChoices: const ['models-pro', 'models-se', 'models-nose'],
                  onChanged: (String? value) => setState(() => modelType = value!),
                ),
                const SizedBox(height: 20),
                DenoiseLevelDropdownWidget(
                  denoiseLevel: denoiseLevel,
                  modelType: modelType,
                  upscaleRatio: upscaleRatio,
                  onChanged: (DenoiseLevel? value) => setState(() => denoiseLevel = value!),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: UpscaleRatioDropdownWidget(
                        upscaleAlgorithmType: UpscaleAlgorithmType.RealCUGAN,
                        upscaleRatio: upscaleRatio,
                        modelType: modelType,
                        onChanged: (String? value) => setState(() => upscaleRatio = value!),
                      ),
                    ),
                    Expanded(
                      child: OutputFormatDropdownWidget(
                        outputFormat: outputFormat,
                        onChanged: (String? value) => setState(() => outputFormat = value!),
                        labelTextAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                ProcessingProfileDropdownWidget(
                  profile: processingProfile,
                  supportsTTAMode: false,
                  onChanged: (ProcessingProfile? value) => setState(() => processingProfile = value!),
                ),
                const SizedBox(height: 12),
                TextField(
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Tile size (-t)',
                    helperText: '0 = auto. Smaller values use less VRAM, but can be slower.',
                  ),
                  keyboardType: TextInputType.number,
                  controller: tileSizeController,
                  onChanged: (value) => tileSize = int.tryParse(value) ?? 0,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<OutputFolderBehavior>(
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'When output folder already exists',
                  ),
                  value: outputFolderBehavior,
                  items: const [
                    DropdownMenuItem(value: OutputFolderBehavior.createNew, child: Text('Create new folder (safe default)')),
                    DropdownMenuItem(value: OutputFolderBehavior.appendOverwrite, child: Text('Append to existing folder (overwrite same name files)')),
                    DropdownMenuItem(value: OutputFolderBehavior.recreate, child: Text('Delete existing folder and recreate (dangerous)')),
                  ],
                  onChanged: (value) => setState(() => outputFolderBehavior = value ?? OutputFolderBehavior.createNew),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
          const Spacer(),
          StartButtonAndProgressBarWidget(
            isProcessing: isProcessing,
            progressPercentage: progressPercentage,
            onButtonPressed: upscaleImage,
          ),
        ],
      ),
    );
  }
}
