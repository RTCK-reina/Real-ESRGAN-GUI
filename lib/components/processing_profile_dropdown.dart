import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:real_esrgan_gui/utils.dart';

class ProcessingProfileDropdownWidget extends StatelessWidget {
  const ProcessingProfileDropdownWidget({
    super.key,
    required this.profile,
    required this.supportsTTAMode,
    required this.onChanged,
  });

  final ProcessingProfile profile;
  final bool supportsTTAMode;
  final void Function(ProcessingProfile?) onChanged;

  @override
  Widget build(BuildContext context) {
    final profiles = [
      ProcessingProfile.balanced,
      ProcessingProfile.speed,
      ProcessingProfile.quality,
    ];

    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text('label.profile'.tr(), style: const TextStyle(fontSize: 16)),
        ),
        Expanded(
          child: DropdownButtonFormField<ProcessingProfile>(
            decoration: const InputDecoration(border: OutlineInputBorder()),
            value: profile,
            items: profiles
                .map((profileItem) => DropdownMenuItem<ProcessingProfile>(
                      value: profileItem,
                      child: Text(
                        'profile.${profileItem.name}'.tr(
                          namedArgs: {'tta': supportsTTAMode ? 'TTA' : '-'},
                        ),
                      ),
                    ))
                .toList(),
            isExpanded: true,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
