/*
Non-Blocking Previews — banco de pruebas de la integración nativa

Reproduce la estructura de widgets de OBS 33 (OBSBasicPreview «preview» y el
QFrame «previewDisabledWidget» en el widget central) y de Vertical Canvas
1.6.x (QDockWidget «VerticalCanvasDock» con un CanvasDock que contiene
«preview», el QFrame con el botón «Habilitar previsualización» y los atajos
VerticalCanvasDock{Show,Hide}Preview registrados en libobs). Comprueba:
- localización de los widgets nativos;
- integración y desintegración de la preview vertical mediante los atajos;
- la opción añadida al principio de los menús nativos (OBS y Vertical);
- recreación de la previsualización si Vertical Canvas recrea su dock.

La activación de la preview principal usa obs_frontend_set_preview_enabled(),
que sin el frontend de OBS no hace nada; esa parte se prueba en OBS.

Uso: nbp-integration-test
*/

#include "native-integration.hpp"
#include "preview-dock.hpp"
#include "preview-shared.hpp"

#include <obs.h>
#include <obs-hotkey.h>

#include <QAction>
#include <QApplication>
#include <QDockWidget>
#include <QFrame>
#include <QMainWindow>
#include <QMenu>
#include <QMouseEvent>
#include <QPointer>
#include <QPushButton>
#include <QTimer>
#include <QVBoxLayout>

#include <cstdio>

extern "C" const char *obs_module_text(const char *lookup)
{
	return lookup;
}

/* Mismos nombres de clase que en OBS y Vertical Canvas. */
class OBSBasicPreview : public QWidget {
	Q_OBJECT
};

class CanvasDock : public QFrame {
	Q_OBJECT

public:
	explicit CanvasDock(QWidget *parent = nullptr) : QFrame(parent)
	{
		auto *layout = new QVBoxLayout(this);
		preview = new QWidget(this);
		preview->setObjectName("preview");
		layout->addWidget(preview, 1);

		disabled = new QFrame;
		auto *disabledLayout = new QVBoxLayout(disabled);
		/* Sin el frontend, obs_frontend_get_locale_string() devuelve NULL. */
		auto *button = new QPushButton(QString(), disabled);
		disabledLayout->addWidget(button);
		connect(button, &QPushButton::clicked, this, [this]() { setPreview(true); });
		layout->addWidget(disabled, 1);
		disabled->setVisible(false);

		hotkeys = obs_hotkey_pair_register_frontend("VerticalCanvasDockShowPreview", "Show",
							      "VerticalCanvasDockHidePreview", "Hide", showHotkey,
							      hideHotkey, this, this);
	}
	~CanvasDock() override { obs_hotkey_pair_unregister(hotkeys); }

	void setPreview(bool enable)
	{
		preview->setVisible(enable);
		disabled->setVisible(!enable);
	}

	static bool showHotkey(void *data, obs_hotkey_pair_id, obs_hotkey_t *, bool pressed)
	{
		auto *dock = static_cast<CanvasDock *>(data);
		if (!pressed || dock->preview->isVisibleTo(dock))
			return false;
		dock->setPreview(true);
		return true;
	}
	static bool hideHotkey(void *data, obs_hotkey_pair_id, obs_hotkey_t *, bool pressed)
	{
		auto *dock = static_cast<CanvasDock *>(data);
		if (!pressed || !dock->preview->isVisibleTo(dock))
			return false;
		dock->setPreview(false);
		return true;
	}

	QWidget *preview = nullptr;
	QFrame *disabled = nullptr;
	obs_hotkey_pair_id hotkeys = OBS_INVALID_HOTKEY_PAIR_ID;
};

/* Como el OBSEventFilter de Vertical Canvas: menú al soltar el botón derecho. */
class MenuOnRelease : public QObject {
public:
	MenuOnRelease(QWidget *menuParent, QStringList *captured) : parent_(menuParent), captured_(captured) {}

protected:
	bool eventFilter(QObject *, QEvent *event) override
	{
		if (event->type() != QEvent::MouseButtonRelease ||
		    static_cast<QMouseEvent *>(event)->button() != Qt::RightButton)
			return false;
		QMenu popup(parent_);
		popup.addAction("Desactivar previsualización");
		QTimer::singleShot(150, &popup, [&popup, this]() {
			for (QAction *action : popup.actions())
				captured_->append(action->isSeparator() ? QStringLiteral("---") : action->text());
			popup.close();
		});
		popup.exec(QPoint(200, 200));
		return true;
	}

private:
	QWidget *parent_;
	QStringList *captured_;
};

namespace {

int failures = 0;

void check(bool condition, const char *what)
{
	printf("[%s] %s\n", condition ? " OK " : "FALLO", what);
	if (!condition)
		failures++;
}

nbp::PreviewShared mainShared;
nbp::PreviewShared verticalShared;

void processEvents(int ms)
{
	QEventLoop loop;
	QTimer::singleShot(ms, &loop, &QEventLoop::quit);
	loop.exec();
}

void rightRelease(QWidget *widget)
{
	QMouseEvent release(QEvent::MouseButtonRelease, QPointF(5, 5), widget->mapToGlobal(QPointF(5, 5)),
			    Qt::RightButton, Qt::NoButton, Qt::NoModifier);
	QApplication::sendEvent(widget, &release);
}

} // namespace

int main(int argc, char **argv)
{
	QCoreApplication::addLibraryPath("/Applications/OBS.app/Contents/PlugIns");
	QApplication app(argc, argv);

	if (!obs_startup("en-US", nullptr, nullptr))
		return 2;
	/* El frontend de OBS activa este enrutado de atajos. */
	obs_hotkey_enable_callback_rerouting(true);

	QMainWindow window;
	auto *central = new QWidget(&window);
	auto *centralLayout = new QVBoxLayout(central);
	auto *obsPreview = new OBSBasicPreview;
	obsPreview->setObjectName("preview");
	auto *obsDisabled = new QFrame;
	obsDisabled->setObjectName("previewDisabledWidget");
	obsDisabled->hide();
	centralLayout->addWidget(obsPreview, 1);
	centralLayout->addWidget(obsDisabled, 1);
	window.setCentralWidget(central);

	auto makeCanvasDock = [&window]() {
		auto *dockWidget = new QDockWidget("Vertical", &window);
		dockWidget->setObjectName("VerticalCanvasDock");
		auto *canvasDock = new CanvasDock(dockWidget);
		dockWidget->setWidget(canvasDock);
		window.addDockWidget(Qt::RightDockWidgetArea, dockWidget);
		dockWidget->show();
		return dockWidget;
	};
	QPointer<QDockWidget> verticalDockWidget = makeCanvasDock();

	bool savedVertical = false;
	auto *integration = new nbp::NativeIntegration(&window, [&](nbp::NativeIntegration::Target target, bool on) {
		if (target == nbp::NativeIntegration::Vertical)
			savedVertical = on;
	});

	auto *mainHome = new QWidget;
	(new QVBoxLayout(mainHome))->setContentsMargins(0, 0, 0, 0);
	auto *verticalHome = new QWidget;
	(new QVBoxLayout(verticalHome))->setContentsMargins(0, 0, 0, 0);
	auto *ownDock = new QDockWidget("Nuestra vertical", &window);
	ownDock->setWidget(verticalHome);
	window.addDockWidget(Qt::LeftDockWidgetArea, ownDock);
	integration->setHome(nbp::NativeIntegration::Main, mainHome, []() { return new nbp::PreviewDock(mainShared); });
	integration->setHome(nbp::NativeIntegration::Vertical, verticalHome,
			     []() { return new nbp::PreviewDock(verticalShared); });

	window.resize(1200, 800);
	window.show();
	processEvents(300);

	/* 1. Estado guardado: vertical integrada. */
	integration->start(false, true);
	processEvents(200);
	auto *canvasDock = static_cast<CanvasDock *>(verticalDockWidget->widget());
	nbp::PreviewDock *view = integration->view(nbp::NativeIntegration::Vertical);
	check(view != nullptr, "previsualización vertical creada");
	check(!canvasDock->preview->isVisibleTo(canvasDock), "el atajo desactiva la preview nativa de Vertical Canvas");
	check(view && view->parentWidget() == canvasDock->disabled, "la del plugin ocupa su hueco");
	if (view)
		printf("  vista %dx%d, hueco %dx%d\n", view->width(), view->height(), canvasDock->disabled->width(),
		       canvasDock->disabled->height());
	check(view && view->geometry() == canvasDock->disabled->rect(), "con el tamaño del hueco");

	/* 2. El hueco cambia de tamaño. */
	verticalDockWidget->setFloating(true);
	verticalDockWidget->resize(500, 900);
	processEvents(300);
	check(view && view->geometry() == canvasDock->disabled->rect(), "sigue el tamaño del hueco al redimensionar");

	/* 3. Desactivar: vuelve a su dock y se reactiva la nativa. */
	integration->setEnabled(nbp::NativeIntegration::Vertical, false);
	processEvents(200);
	check(canvasDock->preview->isVisibleTo(canvasDock), "se reactiva la preview nativa");
	check(view && view->parentWidget() == verticalHome, "la del plugin vuelve a su dock");
	check(!savedVertical, "se guarda el estado desactivado");

	/* 4. Menú nativo de Vertical Canvas: la opción aparece la primera. */
	QStringList verticalMenu;
	MenuOnRelease verticalMenuFilter(canvasDock, &verticalMenu);
	canvasDock->preview->installEventFilter(&verticalMenuFilter);
	/* Nuestro filtro se instaló antes; se reinstala para que vaya primero,
	 * como ocurre en OBS (Vertical Canvas instala el suyo al crear el dock). */
	canvasDock->preview->removeEventFilter(integration);
	canvasDock->preview->installEventFilter(integration);
	rightRelease(canvasDock->preview);
	printf("  menú vertical: %s\n", verticalMenu.join(" | ").toUtf8().constData());
	check(verticalMenu.size() >= 3 && verticalMenu.first() == "Menu.UseOptimized" && verticalMenu.at(1) == "---",
	      "la opción se añade al principio del menú de Vertical Canvas");

	/* 5. Menú nativo de OBS (clic derecho → QContextMenuEvent). */
	QStringList mainMenu;
	obsPreview->setContextMenuPolicy(Qt::CustomContextMenu);
	QObject::connect(obsPreview, &QWidget::customContextMenuRequested, [&]() {
		QMenu popup(&window);
		popup.addAction("Habilitar previsualización");
		QTimer::singleShot(150, &popup, [&]() {
			for (QAction *action : popup.actions())
				mainMenu.append(action->isSeparator() ? QStringLiteral("---") : action->text());
			popup.close();
		});
		popup.exec(QPoint(200, 200));
	});
	QContextMenuEvent contextEvent(QContextMenuEvent::Mouse, QPoint(5, 5), obsPreview->mapToGlobal(QPoint(5, 5)));
	QApplication::sendEvent(obsPreview, &contextEvent);
	printf("  menú principal: %s\n", mainMenu.join(" | ").toUtf8().constData());
	check(!mainMenu.isEmpty() && mainMenu.first() == "Menu.UseOptimized",
	      "la opción se añade al principio del menú de OBS");

	/* 6. Vertical Canvas recrea su dock: la previsualización se recrea y se
	 *    vuelve a integrar en el nuevo. */
	integration->setEnabled(nbp::NativeIntegration::Vertical, true);
	processEvents(200);
	check(savedVertical, "se guarda el estado activado");
	delete verticalDockWidget.data();
	processEvents(200);
	nbp::PreviewDock *recreated = integration->view(nbp::NativeIntegration::Vertical);
	check(recreated && recreated->parentWidget() == verticalHome, "si el dock nativo desaparece, vuelve a su dock");
	verticalDockWidget = makeCanvasDock();
	processEvents(2600);
	auto *newCanvasDock = static_cast<CanvasDock *>(verticalDockWidget->widget());
	recreated = integration->view(nbp::NativeIntegration::Vertical);
	check(recreated && recreated->parentWidget() == newCanvasDock->disabled,
	      "se vuelve a integrar cuando Vertical Canvas recrea su dock");

	integration->shutdown();
	for (auto target : {nbp::NativeIntegration::Main, nbp::NativeIntegration::Vertical}) {
		if (nbp::PreviewDock *v = integration->view(target))
			v->shutdown();
	}
	delete integration;
	window.close();
	delete verticalDockWidget.data();
	obs_shutdown();

	printf("%s (%d fallos)\n", failures ? "PRUEBA FALLIDA" : "PRUEBA SUPERADA", failures);
	return failures ? 1 : 0;
}

#include "integration-test.moc"
