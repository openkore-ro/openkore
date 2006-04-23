#ifndef _CONSOLEUI_H_
#define _CONSOLEUI_H_

#include <pthread.h>
#include <queue>

class ConsoleUICallbacks;

/**
 * This class provides an easy-to-use interface for interactive
 * GNU readline-based console applications.
 */
class ConsoleUI {
private:
	friend class ConsoleUICallbacks;

	static ConsoleUI *instance;
	pthread_t thread;
	pthread_mutex_t inputLock;
	pthread_mutex_t outputLock;
	std::queue<char *> input;
	std::queue<char *> output;
	bool quit;
	bool lineProcessed;

	ConsoleUI();
	~ConsoleUI();

	void *threadMain(void *arg);
	void processOutput();
	void lineRead(char *line);
	bool canRead();

public:
	/**
	 * Returns the unique instance of ConsoleUI.
	 *
	 * @ensure result != NULL
	 */
	static ConsoleUI *getInstance();

	/**
	 * Start this ConsoleUI.
	 */
	void start();

	/**
	 * Stop this ConsoleUI.
	 */
	void stop();

	/**
	 * Print a message to the console.
	 *
	 * @require msg != NULL
	 */
	void print(const char *msg);

	/**
	 * Get the next input line in the input queue.
	 *
	 * @return A line (without newline character) which must be
	 *         freed, or NULL if there is nothing in the queue.
	 */
	char *getInput();
};

#endif /* _CONSOLEUI_H_ */
