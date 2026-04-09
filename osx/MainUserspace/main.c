#include "render_server.h"
#include "dog_satisfy.h"

int main(void)
{
    dog_satisfy_start();
    return render_server_run();
}
