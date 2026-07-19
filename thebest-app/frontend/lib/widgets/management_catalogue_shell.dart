import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

const double managementCatalogueRailWidth = 360;
const double managementCatalogueHeaderHeight = 76;
const double managementCatalogueControlHeight = 44;

double managementCatalogueHeaderHeightFor(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(1);
  final extra = ((scale - 1).clamp(0, 1.6) * 62).toDouble();
  return (managementCatalogueHeaderHeight + extra).clamp(76, 176);
}

extension ManagementCatalogueSizing on BuildContext {
  double get managementCatalogueCardHeight {
    final extraPerLine = MediaQuery.textScalerOf(this).scale(14) - 14;
    return (188 + extraPerLine.clamp(0, 20) * 6).clamp(188, 308).toDouble();
  }

  double get managementCatalogueListHeight {
    final extraPerLine = MediaQuery.textScalerOf(this).scale(14) - 14;
    return (78 + extraPerLine.clamp(0, 20) * 4).clamp(78, 158).toDouble();
  }
}

class ManagementCatalogueShell extends StatelessWidget {
  const ManagementCatalogueShell({
    super.key,
    required this.moduleTitle,
    required this.moduleSubtitle,
    required this.contentTitle,
    required this.itemCountLabel,
    this.addLabel,
    this.onAdd,
    required this.navigation,
    required this.mobileNavigation,
    required this.content,
    this.headerActions,
    this.primaryAction,
    this.toolbar,
  });

  final String moduleTitle;
  final String moduleSubtitle;
  final String contentTitle;
  final String itemCountLabel;
  final String? addLabel;
  final VoidCallback? onAdd;
  final Widget navigation;
  final Widget mobileNavigation;
  final Widget? headerActions;
  final Widget? primaryAction;
  final Widget? toolbar;
  final Widget content;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      backgroundColor: context.appCanvas,
      body: SafeArea(
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: managementCatalogueRailWidth,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.appSurface,
                        border: Border(
                          right: BorderSide(color: context.appBorder),
                        ),
                      ),
                      child: Column(
                        children: [
                          _ModuleHeader(
                            title: moduleTitle,
                            subtitle: moduleSubtitle,
                          ),
                          Divider(height: 1, color: context.appBorder),
                          Expanded(child: navigation),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        CatalogueContentHeader(
                          title: contentTitle,
                          itemCountLabel: itemCountLabel,
                          addLabel: addLabel,
                          onAdd: onAdd,
                          actions: headerActions,
                          primaryAction: primaryAction,
                        ),
                        if (toolbar != null)
                          CatalogueToolbarSurface(child: toolbar!),
                        Expanded(child: content),
                      ],
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  _CompactHeader(
                    title: moduleTitle,
                    subtitle: moduleSubtitle,
                    addLabel: addLabel,
                    onAdd: onAdd,
                    actions: headerActions,
                    primaryAction: primaryAction,
                  ),
                  mobileNavigation,
                  if (toolbar != null) CatalogueToolbarSurface(child: toolbar!),
                  Expanded(child: content),
                ],
              ),
      ),
    );
  }
}

class _ModuleHeader extends StatelessWidget {
  const _ModuleHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: managementCatalogueHeaderHeightFor(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 18, 10),
        child: Row(
          children: [
            const BackButton(),
            const SizedBox(width: 2),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    flex: 3,
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.appText,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Flexible(
                    flex: 2,
                    child: Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.appMuted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CatalogueContentHeader extends StatelessWidget {
  const CatalogueContentHeader({
    super.key,
    required this.title,
    required this.itemCountLabel,
    this.addLabel,
    this.onAdd,
    this.actions,
    this.primaryAction,
  });

  final String title;
  final String itemCountLabel;
  final String? addLabel;
  final VoidCallback? onAdd;
  final Widget? actions;
  final Widget? primaryAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: managementCatalogueHeaderHeightFor(context),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: context.appSurface,
        border: Border(bottom: BorderSide(color: context.appBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  flex: 3,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.appText,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Flexible(
                  flex: 2,
                  child: Text(
                    itemCountLabel,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.appMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (actions != null) ...[
            const SizedBox(width: 12),
            Flexible(
              flex: 3,
              child: Align(
                alignment: Alignment.centerRight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: actions!,
                ),
              ),
            ),
          ],
          if (primaryAction != null) ...[
            const SizedBox(width: 10),
            primaryAction!,
          ] else if (addLabel != null && onAdd != null) ...[
            const SizedBox(width: 10),
            CatalogueAddButton(label: addLabel!, onPressed: onAdd!),
          ],
        ],
      ),
    );
  }
}

class _CompactHeader extends StatelessWidget {
  const _CompactHeader({
    required this.title,
    required this.subtitle,
    this.addLabel,
    this.onAdd,
    this.actions,
    this.primaryAction,
  });

  final String title;
  final String subtitle;
  final String? addLabel;
  final VoidCallback? onAdd;
  final Widget? actions;
  final Widget? primaryAction;

  @override
  Widget build(BuildContext context) {
    final primaryHeight = managementCatalogueHeaderHeightFor(context);
    return Container(
      height: actions == null ? primaryHeight : primaryHeight + 60,
      padding: const EdgeInsets.fromLTRB(4, 8, 14, 8),
      decoration: BoxDecoration(
        color: context.appSurface,
        border: Border(bottom: BorderSide(color: context.appBorder)),
      ),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                const BackButton(),
                const SizedBox(width: 2),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        flex: 2,
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.appText,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Flexible(
                        flex: 3,
                        child: Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.appMuted,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (primaryAction != null)
                  primaryAction!
                else if (addLabel != null && onAdd != null)
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: IconButton.filled(
                      onPressed: onAdd,
                      tooltip: addLabel,
                      style: IconButton.styleFrom(
                        backgroundColor: context.appColors.primary,
                        foregroundColor: Colors.white,
                        disabledForegroundColor: Colors.white70,
                      ),
                      icon: const Icon(
                        Icons.add,
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (actions != null)
            SizedBox(
              height: 52,
              child: Align(
                alignment: Alignment.centerRight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: actions!,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class CatalogueAddButton extends StatelessWidget {
  const CatalogueAddButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: managementCatalogueControlHeight,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.add, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          foregroundColor: context.appColors.primary,
          side: BorderSide(color: context.appColors.primary),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class CataloguePrimaryButton extends StatelessWidget {
  const CataloguePrimaryButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 600) {
      return SizedBox(
        width: 40,
        height: 40,
        child: IconButton.filled(
          onPressed: busy ? null : onPressed,
          tooltip: label,
          style: IconButton.styleFrom(
            backgroundColor: context.appColors.primary,
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white70,
          ),
          icon: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Icon(icon, size: 19, color: Colors.white),
        ),
      );
    }
    return SizedBox(
      height: managementCatalogueControlHeight,
      child: FilledButton.icon(
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(icon, size: 18),
        label: Text(label),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 15),
          backgroundColor: context.appColors.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class CatalogueToolbarSurface extends StatelessWidget {
  const CatalogueToolbarSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 68),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: context.appSurface,
        border: Border(bottom: BorderSide(color: context.appBorder)),
      ),
      child: child,
    );
  }
}

class CatalogueToolbar extends StatelessWidget {
  const CatalogueToolbar({
    super.key,
    required this.searchController,
    required this.searchHint,
    required this.filter,
    required this.sort,
    required this.gridView,
    required this.onGridChanged,
    this.showViewSwitch = true,
  });

  final TextEditingController searchController;
  final String searchHint;
  final Widget filter;
  final Widget sort;
  final bool gridView;
  final ValueChanged<bool> onGridChanged;
  final bool showViewSwitch;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final controls = [
          SizedBox(
            width: constraints.maxWidth < 600 ? 220 : 240,
            child: CatalogueSearchField(
              controller: searchController,
              hintText: searchHint,
            ),
          ),
          filter,
          sort,
          if (showViewSwitch)
            CatalogueViewSwitch(gridView: gridView, onChanged: onGridChanged),
        ];
        return Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: controls,
          ),
        );
      },
    );
  }
}

class CatalogueSearchField extends StatelessWidget {
  const CatalogueSearchField({
    super.key,
    required this.controller,
    required this.hintText,
  });

  final TextEditingController controller;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: managementCatalogueControlHeight,
      child: TextField(
        controller: controller,
        style: TextStyle(
          color: context.appText,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        decoration: InputDecoration(
          hintText: hintText,
          prefixIcon: const Icon(Icons.search, size: 19),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 11),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

class CatalogueToolbarButton extends StatelessWidget {
  const CatalogueToolbarButton({
    super.key,
    required this.icon,
    required this.label,
    this.showChevron = true,
    this.width = 120,
  });

  final IconData icon;
  final String label;
  final bool showChevron;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: managementCatalogueControlHeight,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: context.appSurface,
        border: Border.all(color: context.appBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.appMuted),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.appText,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (showChevron)
            Icon(Icons.arrow_drop_down, color: context.appMuted, size: 20),
        ],
      ),
    );
  }
}

class CatalogueViewSwitch extends StatelessWidget {
  const CatalogueViewSwitch({
    super.key,
    required this.gridView,
    required this.onChanged,
  });

  final bool gridView;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: managementCatalogueControlHeight,
      decoration: BoxDecoration(
        border: Border.all(color: context.appBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ViewButton(
            icon: Icons.grid_view_outlined,
            selected: gridView,
            tooltip: 'Grid view',
            onTap: () => onChanged(true),
          ),
          _ViewButton(
            icon: Icons.view_list_outlined,
            selected: !gridView,
            tooltip: 'List view',
            onTap: () => onChanged(false),
          ),
        ],
      ),
    );
  }
}

class _ViewButton extends StatelessWidget {
  const _ViewButton({
    required this.icon,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 42,
      child: IconButton(
        onPressed: onTap,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: selected
              ? context.appColors.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          foregroundColor: selected
              ? context.appColors.primary
              : context.appMuted,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
        icon: Icon(icon, size: 19),
      ),
    );
  }
}

class CatalogueSidebarTile extends StatelessWidget {
  const CatalogueSidebarTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.count,
    required this.selected,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? context.appColors.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? accent.withValues(alpha: 0.1) : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            constraints: const BoxConstraints(minHeight: 62),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: selected ? Border.all(color: accent) : null,
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: accent, size: 19),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.appText,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.appMuted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (count != null)
                  Container(
                    constraints: const BoxConstraints(minWidth: 26),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? accent.withValues(alpha: 0.14)
                          : context.appCanvas,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: selected ? accent : context.appMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CatalogueMobileNavigation extends StatelessWidget {
  const CatalogueMobileNavigation({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: context.appSurface,
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(children: children),
      ),
    );
  }
}

class CatalogueNavigationChip extends StatelessWidget {
  const CatalogueNavigationChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class CatalogueHeaderChip extends StatelessWidget {
  const CatalogueHeaderChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: SizedBox(
        height: managementCatalogueControlHeight,
        child: ChoiceChip(
          label: Text(label, maxLines: 1),
          selected: selected,
          onSelected: (_) => onTap(),
          padding: const EdgeInsets.symmetric(horizontal: 7),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

class ManagementCatalogueDetailSurface extends StatelessWidget {
  const ManagementCatalogueDetailSurface({
    super.key,
    required this.title,
    required this.isFullScreen,
    required this.child,
    this.subtitle,
    this.footer,
    this.scrollable = true,
  });

  final String title;
  final String? subtitle;
  final bool isFullScreen;
  final Widget child;
  final Widget? footer;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.appSurface,
      child: SafeArea(
        top: isFullScreen,
        child: Column(
          children: [
            Container(
              constraints: const BoxConstraints(minHeight: 66),
              padding: EdgeInsets.fromLTRB(isFullScreen ? 4 : 18, 10, 8, 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: context.appBorder)),
              ),
              child: Row(
                children: [
                  if (isFullScreen) ...[
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 2),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.appText,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.appMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!isFullScreen)
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
            ),
            Expanded(
              child: scrollable
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: child,
                    )
                  : child,
            ),
            if (footer != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                decoration: BoxDecoration(
                  color: context.appSurface,
                  border: Border(top: BorderSide(color: context.appBorder)),
                ),
                child: footer,
              ),
          ],
        ),
      ),
    );
  }
}

class CatalogueDetailEditButton extends StatelessWidget {
  const CatalogueDetailEditButton({
    super.key,
    required this.onPressed,
    this.label = 'Edit',
  });

  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.edit_outlined, size: 18),
      label: Text(label),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(44),
        backgroundColor: context.appColors.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    );
  }
}
