import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Paseo 0.2.0's declarative presentation contract for a git forge.
final class ForgePresentation {
  const ForgePresentation({
    required this.id,
    required this.displayName,
    required this.changeRequestAbbrev,
    required this.changeRequestNoun,
    required this.changeRequestNumberPrefix,
    required this.issueNumberPrefix,
    required this.iconKind,
    required this.cloudHosts,
    this.brandColor,
  });

  final String id;
  final String displayName;
  final String changeRequestAbbrev;
  final String changeRequestNoun;
  final String changeRequestNumberPrefix;
  final String issueNumberPrefix;
  final String iconKind;
  final List<String> cloudHosts;
  final Color? brandColor;
}

const forgePresentations = <ForgePresentation>[
  ForgePresentation(
    id: 'github',
    displayName: 'GitHub',
    changeRequestAbbrev: 'PR',
    changeRequestNoun: 'pull request',
    changeRequestNumberPrefix: '#',
    issueNumberPrefix: '#',
    iconKind: 'github',
    cloudHosts: ['github.com', 'ssh.github.com'],
  ),
  ForgePresentation(
    id: 'gitlab',
    displayName: 'GitLab',
    changeRequestAbbrev: 'MR',
    changeRequestNoun: 'merge request',
    changeRequestNumberPrefix: '!',
    issueNumberPrefix: '#',
    iconKind: 'gitlab',
    cloudHosts: ['gitlab.com'],
    brandColor: Color(0xfffc6d26),
  ),
  ForgePresentation(
    id: 'gitea',
    displayName: 'Gitea',
    changeRequestAbbrev: 'PR',
    changeRequestNoun: 'pull request',
    changeRequestNumberPrefix: '#',
    issueNumberPrefix: '#',
    iconKind: 'gitea',
    cloudHosts: ['gitea.com'],
    brandColor: Color(0xff609926),
  ),
  ForgePresentation(
    id: 'forgejo',
    displayName: 'Forgejo',
    changeRequestAbbrev: 'PR',
    changeRequestNoun: 'pull request',
    changeRequestNumberPrefix: '#',
    issueNumberPrefix: '#',
    iconKind: 'forgejo',
    cloudHosts: [],
    brandColor: Color(0xfffb923c),
  ),
  ForgePresentation(
    id: 'codeberg',
    displayName: 'Codeberg',
    changeRequestAbbrev: 'PR',
    changeRequestNoun: 'pull request',
    changeRequestNumberPrefix: '#',
    issueNumberPrefix: '#',
    iconKind: 'codeberg',
    cloudHosts: ['codeberg.org'],
    brandColor: Color(0xff2185d0),
  ),
];

ForgePresentation? getForgePresentation(String id) {
  for (final presentation in forgePresentations) {
    if (presentation.id == id) return presentation;
  }
  return null;
}

ForgePresentation getForgePresentationOrNeutral(String id) =>
    getForgePresentation(id) ??
    ForgePresentation(
      id: id,
      displayName: id,
      changeRequestAbbrev: 'PR',
      changeRequestNoun: 'pull request',
      changeRequestNumberPrefix: '#',
      issueNumberPrefix: '#',
      iconKind: 'git',
      cloudHosts: const [],
    );

Color? getForgeBrandColor(String iconKind) =>
    getForgePresentation(iconKind)?.brandColor;

/// Dedicated brand glyph with Paseo's generic pull-request fallback.
class ForgeBrandIcon extends StatelessWidget {
  const ForgeBrandIcon({
    super.key,
    required this.iconKind,
    required this.size,
    required this.color,
    this.useBrandColor = true,
  });

  final String iconKind;
  final double size;
  final Color color;
  final bool useBrandColor;

  @override
  Widget build(BuildContext context) {
    final svg = _forgeIconSvgs[iconKind];
    if (svg == null) {
      return Icon(FluentIcons.branch_fork2, size: size, color: color);
    }
    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(
        useBrandColor ? getForgeBrandColor(iconKind) ?? color : color,
        BlendMode.srcIn,
      ),
    );
  }
}

const _forgeIconSvgs = <String, String>{
  'github': '''
<svg viewBox="0 -0.5 25 25"><path d="m12.301 0h.093c2.242 0 4.34.613 6.137 1.68l-.055-.031c1.871 1.094 3.386 2.609 4.449 4.422l.031.058c1.04 1.769 1.654 3.896 1.654 6.166 0 5.406-3.483 10-8.327 11.658l-.087.026c-.063.02-.135.031-.209.031-.162 0-.312-.054-.433-.144l.002.001c-.128-.115-.208-.281-.208-.466v-.014q0-.048.008-1.226t.008-2.154c.007-.075.011-.161.011-.249 0-.792-.323-1.508-.844-2.025.618-.061 1.176-.163 1.718-.305l-.076.017c.573-.16 1.073-.373 1.537-.642l-.031.017c.508-.28.938-.636 1.292-1.058l.006-.007c.372-.476.663-1.036.84-1.645l.009-.035c.209-.683.329-1.468.329-2.281v-.129c0-.022.001-.047.001-.072 0-1.248-.482-2.383-1.269-3.23.168-.44.265-.948.265-1.479 0-.649-.145-1.263-.404-1.814-.115-.022-.246-.035-.381-.035-.334 0-.649.078-.929.216-.568.21-1.054.448-1.512.726l-.609.384c-.922-.264-1.981-.416-3.075-.416s-2.153.152-3.157.436q-.256-.176-.681-.433c-.373-.214-.814-.421-1.272-.595-.293-.154-.64-.244-1.009-.244-.124 0-.246.01-.364.03-.248.524-.393 1.139-.393 1.788 0 .531.097 1.04.275 1.509-.785.844-1.266 1.979-1.266 3.227v.202c0 .809.12 1.591.344 2.327.189.643.476 1.202.85 1.693.354.435.782.793 1.267 1.062.432.252.933.465 1.46.614.466.125 1.024.227 1.595.284-.431.428-.718 1-.784 1.638-.207.101-.448.183-.699.236-.256.051-.549.08-.85.08h-.063c-.394-.008-.756-.136-1.055-.348-.371-.259-.671-.595-.881-.986-.198-.336-.459-.614-.768-.827-.225-.169-.49-.301-.776-.38l-.32-.048c-.023-.002-.05-.003-.077-.003-.14 0-.273.028-.394.077q-.128.072-.08.184c.039.086.087.16.145.225.061.072.13.135.205.19l.112.08c.283.148.516.354.693.603.191.237.359.505.494.792l.16.368c.135.402.38.738.7.981.3.234.662.402 1.057.478.33.064.714.104 1.106.112.045.002.097.002.15.002.261 0 .517-.021.767-.062l.368-.064q0 .609.008 1.418t.008.873v.014c0 .185-.08.351-.208.466-.119.089-.268.143-.431.143-.075 0-.147-.011-.214-.032-4.929-1.689-8.409-6.283-8.409-11.69 0-2.268.612-4.393 1.681-6.219 1.094-1.871 2.609-3.386 4.422-4.449 1.739-1.034 3.835-1.645 6.073-1.645z"/></svg>
''',
  'gitlab': '''
<svg viewBox="0 0 24 24"><path d="M23.6004 9.5927l-.0337-.0862L20.3.9814a.851.851 0 0 0-.3362-.405.8748.8748 0 0 0-.9997.0539.8748.8748 0 0 0-.29.4399l-2.2055 6.748H7.5375l-2.2057-6.748a.8573.8573 0 0 0-.29-.4412.8748.8748 0 0 0-.9997-.0537.8585.8585 0 0 0-.3362.4049L.4332 9.5015l-.0325.0862a6.0657 6.0657 0 0 0 2.0119 7.0105l.0113.0087.03.0213 4.976 3.7264 2.462 1.8633 1.4995 1.1321a1.0085 1.0085 0 0 0 1.2197 0l1.4995-1.1321 2.462-1.8633 5.006-3.7489.0125-.01a6.0682 6.0682 0 0 0 2.0094-7.003z"/></svg>
''',
  'gitea': '''
<svg viewBox="0 0 24 24"><path d="M4.209 4.603c-.247 0-.525.02-.84.088-.333.07-1.28.283-2.054 1.027C-.403 7.25.035 9.685.089 10.052c.065.446.263 1.687 1.21 2.768 1.749 2.141 5.513 2.092 5.513 2.092s.462 1.103 1.168 2.119c.955 1.263 1.936 2.248 2.89 2.367 2.406 0 7.212-.004 7.212-.004s.458.004 1.08-.394c.535-.324 1.013-.893 1.013-.893s.492-.527 1.18-1.73c.21-.37.385-.729.538-1.068 0 0 2.107-4.471 2.107-8.823-.042-1.318-.367-1.55-.443-1.627-.156-.156-.366-.153-.366-.153s-4.475.252-6.792.306c-.508.011-1.012.023-1.512.027v4.474l-.634-.301c0-1.39-.004-4.17-.004-4.17-1.107.016-3.405-.084-3.405-.084s-5.399-.27-5.987-.324c-.187-.011-.401-.032-.648-.032zm.354 1.832h.111s.271 2.269.6 3.597C5.549 11.147 6.22 13 6.22 13s-.996-.119-1.641-.348c-.99-.324-1.409-.714-1.409-.714s-.73-.511-1.096-1.52C1.444 8.73 2.021 7.7 2.021 7.7s.32-.859 1.47-1.145c.395-.106.863-.12 1.072-.12zm8.33 2.554c.26.003.509.127.509.127l.868.422-.529 1.075a.686.686 0 0 0-.614.359.685.685 0 0 0 .072.756l-.939 1.924a.69.69 0 0 0-.66.527.687.687 0 0 0 .347.763.686.686 0 0 0 .867-.206.688.688 0 0 0-.069-.882l.916-1.874a.667.667 0 0 0 .237-.02.657.657 0 0 0 .271-.137 8.826 8.826 0 0 1 1.016.512.761.761 0 0 1 .286.282c.073.21-.073.569-.073.569-.087.29-.702 1.55-.702 1.55a.692.692 0 0 0-.676.477.681.681 0 1 0 1.157-.252c.073-.141.141-.282.214-.431.19-.397.515-1.16.515-1.16.035-.066.218-.394.103-.814-.095-.435-.48-.638-.48-.638-.467-.301-1.116-.58-1.116-.58s0-.156-.042-.27a.688.688 0 0 0-.148-.241l.516-1.062 2.89 1.401s.48.218.583.619c.073.282-.019.534-.069.657-.24.587-2.1 4.317-2.1 4.317s-.232.554-.748.588a1.065 1.065 0 0 1-.393-.045l-.202-.08-4.31-2.1s-.417-.218-.49-.596c-.083-.31.104-.691.104-.691l2.073-4.272s.183-.37.466-.497a.855.855 0 0 1 .35-.077z"/></svg>
''',
  'forgejo': '''
<svg viewBox="0 0 24 24"><path d="M16.7773 0c1.6018 0 2.9004 1.2986 2.9004 2.9005s-1.2986 2.9004-2.9004 2.9004c-1.0854 0-2.0315-.596-2.5288-1.4787H12.91c-2.3322 0-4.2272 1.8718-4.2649 4.195l-.0007 2.1175a7.0759 7.0759 0 0 1 4.148-1.4205l.1176-.001 1.3385.0002c.4973-.8827 1.4434-1.4788 2.5288-1.4788 1.6018 0 2.9004 1.2986 2.9004 2.9005s-1.2986 2.9004-2.9004 2.9004c-1.0854 0-2.0315-.596-2.5288-1.4787H12.91c-2.3322 0-4.2272 1.8718-4.2649 4.195l-.0007 2.319c.8827.4973 1.4788 1.4434 1.4788 2.5287 0 1.602-1.2986 2.9005-2.9005 2.9005-1.6018 0-2.9004-1.2986-2.9004-2.9005 0-1.0853.596-2.0314 1.4788-2.5287l-.0002-9.9831c0-3.887 3.1195-7.0453 6.9915-7.108l.1176-.001h1.3385C14.7458.5962 15.692 0 16.7773 0ZM7.2227 19.9052c-.6596 0-1.1943.5347-1.1943 1.1943s.5347 1.1943 1.1943 1.1943 1.1944-.5347 1.1944-1.1943-.5348-1.1943-1.1944-1.1943Zm9.5546-10.4644c-.6596 0-1.1944.5347-1.1944 1.1943s.5348 1.1943 1.1944 1.1943c.6596 0 1.1943-.5347 1.1943-1.1943s-.5347-1.1943-1.1943-1.1943Zm0-7.7346c-.6596 0-1.1944.5347-1.1944 1.1943s.5348 1.1943 1.1944 1.1943c.6596 0 1.1943-.5347 1.1943-1.1943s-.5347-1.1943-1.1943-1.1943Z"/></svg>
''',
  'codeberg': '''
<svg viewBox="0 0 24 24"><path d="M11.999.747A11.974 11.974 0 0 0 0 12.75c0 2.254.635 4.465 1.833 6.376L11.837 6.19c.072-.092.251-.092.323 0l4.178 5.402h-2.992l.065.239h3.113l.882 1.138h-3.674l.103.374h3.86l.777 1.003h-4.358l.135.483h4.593l.695.894h-5.038l.165.589h5.326l.609.785h-5.717l.182.65h6.038l.562.727h-6.397l.183.65h6.717A12.003 12.003 0 0 0 24 12.75 11.977 11.977 0 0 0 11.999.747zm3.654 19.104.182.65h5.326c.173-.204.353-.433.513-.65zm.385 1.377.18.65h3.563c.233-.198.485-.428.712-.65zm.383 1.377.182.648h1.203c.356-.204.685-.412 1.042-.648z"/></svg>
''',
};
