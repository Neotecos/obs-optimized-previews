/*
Non-Blocking Previews
Copyright (C) 2026 Alekstyle

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License along
with this program. If not, see <https://www.gnu.org/licenses/>
*/

#include "preview-dock.hpp"

#include <obs-module.h>
#include <util/platform.h>

#include <QActionGroup>
#include <QContextMenuEvent>
#include <QMenu>

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

/* Tiempo que el tamaño del dock debe permanecer estable antes de pedir al
 * hilo gráfico superficies nuevas; mientras tanto Core Animation escala la
 * imagen anterior. Evita recrear superficies en cada paso de un arrastre. */
static const CFTimeInterval kResizeSettleSeconds = 0.15;

@interface NBPPreviewView : NSView
- (instancetype)initWithShared:(nbp::PreviewShared *)shared;
- (void)setQtVisible:(BOOL)visible;
- (void)setMessage:(NSString *)message;
- (void)shutdown;
@end

@implementation NBPPreviewView {
	nbp::PreviewShared *_shared;
	CADisplayLink *_displayLink;
	CATextLayer *_messageLayer;
	IOSurfaceRef _current;
	uint64_t _seenSerial;
	uint64_t _pendingSize;
	uint64_t _sentSize;
	CFTimeInterval _pendingSince;
	BOOL _qtVisible;
	BOOL _shutdown;
}

- (instancetype)initWithShared:(nbp::PreviewShared *)shared
{
	self = [super initWithFrame:NSMakeRect(0, 0, 1, 1)];
	if (!self)
		return nil;

	_shared = shared;

	/* Vista que aloja su propia capa: AppKit no dibuja nada en ella. */
	CALayer *layer = [CALayer layer];
	layer.contentsGravity = kCAGravityResizeAspect;
	layer.backgroundColor = NSColor.blackColor.CGColor;
	layer.opaque = YES;
	layer.actions = @{@"contents": [NSNull null], @"bounds": [NSNull null], @"position": [NSNull null]};
	self.layer = layer;
	self.wantsLayer = YES;
	self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
	self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

	_messageLayer = [CATextLayer layer];
	_messageLayer.alignmentMode = kCAAlignmentCenter;
	_messageLayer.foregroundColor = NSColor.secondaryLabelColor.CGColor;
	_messageLayer.fontSize = 13;
	_messageLayer.wrapped = YES;
	_messageLayer.hidden = YES;
	_messageLayer.actions = @{@"contents": [NSNull null], @"bounds": [NSNull null], @"position": [NSNull null],
				  @"hidden": [NSNull null]};
	[layer addSublayer:_messageLayer];

	return self;
}

- (void)dealloc
{
	if (_current)
		CFRelease(_current);
}

/* Los eventos de ratón pasan al QWidget (menú contextual de Qt). */
- (NSView *)hitTest:(NSPoint)point
{
	(void)point;
	return nil;
}

- (BOOL)isOpaque
{
	return YES;
}

- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	[self updateDisplayLink];
	[self updateScale];
}

- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];
	[self updateScale];
}

- (void)setFrameSize:(NSSize)newSize
{
	[super setFrameSize:newSize];
	[self layoutMessage];
}

- (void)setQtVisible:(BOOL)visible
{
	_qtVisible = visible;
	[self updateDisplayLink];
	if (!visible)
		[self publishSize:0];
}

- (void)setMessage:(NSString *)message
{
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_messageLayer.string = message ?: @"";
	_messageLayer.hidden = message.length == 0;
	if (message.length) {
		self.layer.contents = nil;
		[self releaseCurrent];
	}
	[self layoutMessage];
	[CATransaction commit];
}

- (void)shutdown
{
	_shutdown = YES;
	[self updateDisplayLink];
	[self publishSize:0];
	[self releaseCurrent];
	/* El estado compartido puede liberarse al descargar el módulo, antes que
	 * este NSView: a partir de aquí no se vuelve a tocar. */
	_shared = nullptr;
}

- (void)updateScale
{
	CGFloat scale = self.window ? self.window.backingScaleFactor : 1.0;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	self.layer.contentsScale = scale;
	_messageLayer.contentsScale = scale;
	[CATransaction commit];
}

- (void)layoutMessage
{
	NSRect bounds = self.bounds;
	CGFloat height = 60;
	_messageLayer.frame = CGRectMake(12, (bounds.size.height - height) / 2, MAX(bounds.size.width - 24, 1), height);
}

- (void)updateDisplayLink
{
	BOOL wanted = self.window != nil && _qtVisible && !_shutdown;

	if (wanted && !_displayLink) {
		/* Sigue a la pantalla de la ventana y se dispara en el hilo
		 * principal; en modo común sigue funcionando durante
		 * redimensionados y menús. */
		_displayLink = [self displayLinkWithTarget:self selector:@selector(step:)];
		[_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	} else if (!wanted && _displayLink) {
		[_displayLink invalidate];
		_displayLink = nil;
	}
}

- (void)releaseCurrent
{
	if (_shared) {
		os_unfair_lock_lock(&_shared->lock);
		_shared->displayed = nullptr;
		os_unfair_lock_unlock(&_shared->lock);
	}

	if (_current) {
		CFRelease(_current);
		_current = nullptr;
	}
}

- (void)publishSize:(uint64_t)size
{
	if (!_shared)
		return;
	_sentSize = size;
	_shared->requestedSize.store(size, std::memory_order_relaxed);
}

- (BOOL)isActuallyVisible
{
	NSWindow *window = self.window;
	if (!window || !_qtVisible || _shutdown || self.hiddenOrHasHiddenAncestor)
		return NO;
	if (!(window.occlusionState & NSWindowOcclusionStateVisible))
		return NO;
	return YES;
}

- (void)updateRequestedSize:(CFTimeInterval)now
{
	if (![self isActuallyVisible] || _messageLayer.hidden == NO) {
		if (_sentSize)
			[self publishSize:0];
		_pendingSize = 0;
		return;
	}

	NSRect backing = [self convertRectToBacking:self.bounds];
	uint32_t width = uint32_t(MAX(backing.size.width, 0));
	uint32_t height = uint32_t(MAX(backing.size.height, 0));
	uint64_t size = (width && height) ? nbp::PreviewShared::packSize(width, height) : 0;

	if (size == _sentSize) {
		_pendingSize = size;
		return;
	}

	if (size != _pendingSize) {
		_pendingSize = size;
		_pendingSince = now;
	}

	/* La primera vez (o al volver a ser visible) se publica de inmediato. */
	if (_sentSize == 0 || now - _pendingSince >= kResizeSettleSeconds)
		[self publishSize:size];
}

- (void)step:(CADisplayLink *)link
{
	(void)link;
	if (!_shared)
		return;
	[self updateRequestedSize:CACurrentMediaTime()];

	if (_messageLayer.hidden == NO)
		return;

	IOSurfaceRef next = nullptr;
	uint64_t frameTime = 0;
	os_unfair_lock_lock(&_shared->lock);
	if (_shared->latestSerial != _seenSerial) {
		_seenSerial = _shared->latestSerial;
		next = _shared->latest;
		frameTime = _shared->latestFrameTime;
		if (next) {
			CFRetain(next);
			_shared->displayed = next;
		}
	}
	os_unfair_lock_unlock(&_shared->lock);

	if (!next)
		return;

	const uint64_t now = os_gettime_ns();
	if (frameTime && now > frameTime)
		_shared->recordLatency(now - frameTime);

	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	self.layer.contents = (__bridge id)next;
	[CATransaction commit];

	if (_current)
		CFRelease(_current);
	_current = next;
}

@end

namespace nbp {

PreviewDock::PreviewDock(PreviewShared &shared, QWidget *parent) : QWidget(parent), shared_(shared)
{
	/* Igual que OBSQTDisplay: widget nativo en el que Qt no pinta. */
	setAttribute(Qt::WA_PaintOnScreen);
	setAttribute(Qt::WA_StaticContents);
	setAttribute(Qt::WA_NoSystemBackground);
	setAttribute(Qt::WA_OpaquePaintEvent);
	setAttribute(Qt::WA_DontCreateNativeAncestors);
	setAttribute(Qt::WA_NativeWindow);
	setMinimumSize(160, 90);

	NBPPreviewView *view = [[NBPPreviewView alloc] initWithShared:&shared_];
	view_ = (void *)CFBridgingRetain(view);
}

PreviewDock::~PreviewDock()
{
	shutdown();
	if (view_) {
		NBPPreviewView *view = (NBPPreviewView *)CFBridgingRelease(view_);
		[view removeFromSuperview];
		view_ = nullptr;
	}
}

void PreviewDock::setMessage(const QString &message)
{
	message_ = message;
	if (view_)
		[(__bridge NBPPreviewView *)view_ setMessage:message.toNSString()];
}

void PreviewDock::shutdown()
{
	if (shutdown_)
		return;
	shutdown_ = true;
	if (view_)
		[(__bridge NBPPreviewView *)view_ shutdown];
}

void PreviewDock::attachView()
{
	if (!view_ || shutdown_)
		return;

	NSView *host = (__bridge NSView *)reinterpret_cast<void *>(winId());
	NBPPreviewView *view = (__bridge NBPPreviewView *)view_;
	if (!host || view.superview == host)
		return;

	[view removeFromSuperview];
	view.frame = host.bounds;
	[host addSubview:view];
}

void PreviewDock::detachView()
{
	if (view_)
		[(__bridge NBPPreviewView *)view_ removeFromSuperview];
}

bool PreviewDock::event(QEvent *event)
{
	switch (event->type()) {
	case QEvent::WinIdChange:
		/* Qt recrea el NSView al acoplar/desacoplar el dock. */
		if (isVisible())
			attachView();
		break;
	case QEvent::PlatformSurface:
		if (static_cast<QPlatformSurfaceEvent *>(event)->surfaceEventType() ==
		    QPlatformSurfaceEvent::SurfaceAboutToBeDestroyed)
			detachView();
		break;
	default:
		break;
	}

	return QWidget::event(event);
}

void PreviewDock::showEvent(QShowEvent *event)
{
	QWidget::showEvent(event);
	attachView();
	if (view_)
		[(__bridge NBPPreviewView *)view_ setQtVisible:YES];
}

void PreviewDock::hideEvent(QHideEvent *event)
{
	if (view_)
		[(__bridge NBPPreviewView *)view_ setQtVisible:NO];
	QWidget::hideEvent(event);
}

void PreviewDock::contextMenuEvent(QContextMenuEvent *event)
{
	QMenu menu(this);
	QMenu *fpsMenu = menu.addMenu(QString::fromUtf8(obs_module_text("Menu.FpsLimit")));
	auto *group = new QActionGroup(fpsMenu);

	const unsigned int current = shared_.fpsLimit.load(std::memory_order_relaxed);
	const struct {
		unsigned int fps;
		const char *label;
	} options[] = {
		{0, "Menu.FpsLimit.None"},
		{60, "Menu.FpsLimit.60"},
		{30, "Menu.FpsLimit.30"},
		{20, "Menu.FpsLimit.20"},
	};

	for (const auto &option : options) {
		QAction *action = fpsMenu->addAction(QString::fromUtf8(obs_module_text(option.label)));
		action->setCheckable(true);
		action->setChecked(option.fps == current);
		group->addAction(action);
		const unsigned int fps = option.fps;
		connect(action, &QAction::triggered, this, [this, fps]() {
			shared_.fpsLimit.store(fps, std::memory_order_relaxed);
			emit fpsLimitSelected(fps);
		});
	}

	if (menuExtender_)
		menuExtender_(&menu);

	menu.exec(event->globalPos());
}

} // namespace nbp
