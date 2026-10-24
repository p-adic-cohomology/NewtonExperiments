#define _POSIX_C_SOURCE 200809L

#include "funsearch.h"

int main(int argc, char **argv)
{
    const char *instance = argc > 1 ? argv[1] :
        "family=plane,d=5,p=7,reward=mixed,beta=0.5,eps=0.01,exclude_ss=true";
    if (fs_init(instance) != 0)
        return 1;
    fs_fini();
    return 0;
}
