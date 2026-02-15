import 'dart:convert';
import 'dart:io';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:real_esrgan_gui/components/io_form.dart';
import 'package:real_esrgan_gui/components/model_type_dropdown.dart';
import 'package:real_esrgan_gui/components/output_format_dropdown.dart';
import 'package:real_esrgan_gui/components/processing_profile_dropdown.dart';
import 'package:real_esrgan_gui/components/start_button_and_progress_bar.dart';
import 'package:real_esrgan_gui/components/upscale_ratio_dropdown.dart';
import 'package:real_esrgan_gui/utils.dart';

class RealESRGANTabPage extends StatefulWidget {
  const RealESRGANTabPage({super.key});

  @override
  State<RealESRGANTabPage> createState() => RealESRGANTabPageState();
}

class RealESRGANTabPageState extends State<RealESRGANTabPage> {
  IOFormMode ioFormMode = IOFormMode.fileSelection;
  TextEditingController inputFileController = TextEditingController();
  TextEditingController outputFileController = TextEditingController();
  TextEditingController inputFolderController = TextEditingController();
  TextEditingController outputFolderController = TextEditingController();

  String modelType = 'realesr-animevideov3';
  String upscaleRatio = '4x';
  String outputFormat = 'jpg';
  ProcessingProfile processingProfile = ProcessingProfile.balanced;
  OutputFolderBehavior outputFolderBehavior = OutputFolderBehavior.createNew;
  bool enableScaleStabilization = true;
  int tileSize = 0;
  final TextEditingController tileSizeController = TextEditingController(text: '0');

  double progressPercentage = 0;
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

    setState(() {
      progressPercentage = 0;
      isCancelRequested = false;
      isProcessing = true;
      latestStdoutLog = '';
      latestStderrLog = '';
    });

    var progressStep = 100 / imageFiles.length;

    for (var progressIndex = 0; progressIndex < imageFiles.length; progressIndex++) {
      if (isCancelRequested) break;

      var executablePath = getUpscaleAlgorithmExecutablePath(UpscaleAlgorithmType.RealESRGAN);
      var runtimeOptions = UpscaleRuntimeOptions.fromProfile(profile: processingProfile, supportsTTA: true);

      var requestScale = int.parse(upscaleRatio.replaceAll('x', ''));
      var useStabilization = enableScaleStabilization && (requestScale == 2 || requestScale == 3);
      var processScale = useStabilization ? 4 : requestScale;
      var outputPath = imageFiles[progressIndex]['output']!;
      var tmpOutputPath = useStabilization ? '$outputPath.__4x_tmp__' : outputPath;
      if (useStabilization) {
        latestStdoutLog += '[info] 4x→downscale mode enabled for $outputPath\n';
      }

      final args = [
        '-i', imageFiles[progressIndex]['input']!,
        '-o', tmpOutputPath,
        '-n', modelType,
        '-s', processScale.toString(),
        '-f', outputFormat,
        '-j', runtimeOptions.threadOption,
        if (tileSize > 0) ...['-t', tileSize.toString()],
        if (runtimeOptions.enableTTAMode) '-x',
      ];

      try {
        process = await Process.start(executablePath, args, workingDirectory: path.dirname(executablePath));
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

      process!.stdout.transform(utf8.decoder).listen((line) {
        stdoutLines.add(line);
      });
      process!.stderr.transform(utf8.decoder).listen((line) {
        stderrLines.add(line);
        var progressMatch = RegExp(r'([0-9]+\.[0-9]+)%').firstMatch(line);
        if (progressMatch != null) {
          var progressData = double.parse(progressMatch.group(1) ?? '0');
          if (mounted) {
            setState(() {
              progressPercentage = (progressStep * progressIndex) + (progressData / imageFiles.length);
            });
          }
        }
      });

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

      if (useStabilization) {
        try {
          await downscaleFrom4x(tmpOutputPath, outputPath, requestScale);
          await File(tmpOutputPath).delete();
        } catch (error) {
          setState(() {
            isProcessing = false;
            progressPercentage = 0;
          });
          showSnackBar(context: context, content: SelectableText('I/O post-process failed: $error'));
          return;
        }
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

  Future<void> downscaleFrom4x(String inputPath, String outputPath, int requestedScale) async {
    final source = await File(inputPath).readAsBytes();
    final decoded = img.decodeImage(source);
    if (decoded == null) {
      throw Exception('failed to decode upscaled image: $inputPath');
    }
    final targetWidth = (decoded.width * requestedScale ~/ 4);
    final targetHeight = (decoded.height * requestedScale ~/ 4);
    final resized = img.copyResize(
      decoded,
      width: targetWidth,
      height: targetHeight,
      interpolation: img.Interpolation.cubic,
    );

    List<int> encoded;
    switch (outputFormat) {
      case 'png':
        encoded = img.encodePng(resized, level: 6);
        break;
      case 'webp':
        encoded = img.encodeWebp(resized, quality: 95);
        break;
      case 'jpg':
      default:
        encoded = img.encodeJpg(resized, quality: 95);
        break;
    }
    await File(outputPath).writeAsBytes(encoded, flush: true);
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
    return Column(
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
                upscaleAlgorithmType: UpscaleAlgorithmType.RealESRGAN,
                modelType: modelType,
                modelTypeChoices: const ['realesr-animevideov3', 'realesrgan-x4plus-anime', 'realesrgan-x4plus'],
                onChanged: (String? value) {
                  setState(() => modelType = value!);
                },
              ),
              const SizedBox(height: 20),
              UpscaleRatioDropdownWidget(
                upscaleAlgorithmType: UpscaleAlgorithmType.RealESRGAN,
                upscaleRatio: upscaleRatio,
                modelType: modelType,
                onChanged: (String? value) {
                  setState(() => upscaleRatio = value!);
                },
              ),
              const SizedBox(height: 20),
              OutputFormatDropdownWidget(
                outputFormat: outputFormat,
                onChanged: (String? value) {
                  setState(() => outputFormat = value!);
                },
              ),
              const SizedBox(height: 20),
              ProcessingProfileDropdownWidget(
                profile: processingProfile,
                supportsTTAMode: true,
                onChanged: (ProcessingProfile? value) {
                  setState(() => processingProfile = value!);
                },
              ),
              const SizedBox(height: 20),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('2x/3x stabilization (4x→downscale)'),
                subtitle: const Text('Use 4x upscaling internally and downscale to the target ratio.'),
                value: enableScaleStabilization,
                onChanged: (value) => setState(() => enableScaleStabilization = value),
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
    );
  }
}
